#!/usr/bin/env bash

set -euo pipefail

if [[ "${1:-}" == "--help" || "${1:-}" == "-h" ]]; then
  cat <<'EOF'
用法：
  npm run dev:all
  ./start-cloudex.sh

可选环境变量：
  AUTH_TOKEN  手机访问 Cloudex 的 Bearer Token；省略时本次运行自动生成。
  HOST        Cloudex 监听地址，默认 0.0.0.0。
  PORT        Cloudex 监听端口，默认 8787。
  CODEX_BIN   standalone Codex CLI 路径。
  EXPO_HOST   Expo/Metro 对手机暴露的主机名；默认优先 Tailscale IP，其次局域网 IP。
  EXPO_PORT   Expo/Metro 端口，默认 8081。
  EXPO_CLEAR_CACHE  是否启动时清 Metro 缓存；默认 false。
  EXPO_CI_MODE      是否用 CI 模式启动 Metro；默认 true，可规避部分 macOS/Watchman 卡死。
EOF
  exit 0
fi

PROJECT_DIR="$(cd "$(dirname "$0")" && pwd)"
CODEX_BIN="${CODEX_BIN:-$HOME/.codex/packages/standalone/current/codex}"
HOST="${HOST:-0.0.0.0}"
PORT="${PORT:-8787}"
EXPO_PORT="${EXPO_PORT:-8081}"
EXPO_CLEAR_CACHE="${EXPO_CLEAR_CACHE:-false}"
EXPO_CI_MODE="${EXPO_CI_MODE:-true}"
QRCODE_BIN="${QRCODE_BIN:-}"
QR_FILE="${CLOUDEX_QR_FILE:-/tmp/cloudex-expo-qr.svg}"
EXPO_READY_TIMEOUT="${EXPO_READY_TIMEOUT:-45}"
AUTH_TOKEN_FILE="${CLOUDEX_AUTH_TOKEN_FILE:-/tmp/cloudex-auth-token}"

if [[ ! -x "$CODEX_BIN" ]]; then
  echo "找不到 standalone Codex CLI：$CODEX_BIN" >&2
  echo "请先安装 Codex，或通过 CODEX_BIN 指定可执行文件路径。" >&2
  exit 1
fi

if [[ -z "${AUTH_TOKEN:-}" ]]; then
  if [[ -f "$AUTH_TOKEN_FILE" ]]; then
    AUTH_TOKEN="$(cat "$AUTH_TOKEN_FILE")"
    echo "未设置 AUTH_TOKEN，已复用上次保存的 Token。"
  else
    umask 077
    AUTH_TOKEN="$(node -e 'console.log(require("node:crypto").randomBytes(24).toString("base64url"))')"
    printf '%s\n' "$AUTH_TOKEN" > "$AUTH_TOKEN_FILE"
    echo "未设置 AUTH_TOKEN，已为本次运行生成并保存临时 Token。"
  fi
  export AUTH_TOKEN
fi

export HOST PORT AUTH_TOKEN
export EXPO_PUBLIC_CLOUDEX_AUTH_TOKEN="$AUTH_TOKEN"

print_qr() {
  local label="$1"
  local value="$2"
  [[ -z "$value" ]] && return
  echo
  echo "$label"
  node -e '
    const fs = require("node:fs");
    const qrcodeTerminal = require("qrcode-terminal");
    const QRCode = require("qrcode-terminal/vendor/QRCode");
    const QRErrorCorrectLevel = require("qrcode-terminal/vendor/QRCode/QRErrorCorrectLevel");
    const input = process.argv[1];
    const output = process.argv[2];
    qrcodeTerminal.generate(input, { small: true });
    const qr = new QRCode(-1, QRErrorCorrectLevel.L);
    qr.addData(input);
    qr.make();
    const margin = 3;
    const cell = 10;
    const count = qr.getModuleCount();
    const size = (count + margin * 2) * cell;
    let svg = `<svg xmlns="http://www.w3.org/2000/svg" width="${size}" height="${size}" viewBox="0 0 ${size} ${size}">`;
    svg += `<rect width="100%" height="100%" fill="#fff"/>`;
    qr.modules.forEach((row, y) => row.forEach((dark, x) => {
      if (dark) svg += `<rect x="${(x + margin) * cell}" y="${(y + margin) * cell}" width="${cell}" height="${cell}" fill="#000"/>`;
    }));
    svg += `</svg>`;
    fs.writeFileSync(output, svg);
  ' "$value" "$QR_FILE"
  echo "  如果终端二维码不好扫，备用图片：$QR_FILE"
}

LAN_IP="${CLOUDEX_LAN_IP:-}"
if [[ -z "$LAN_IP" ]] && command -v ipconfig >/dev/null 2>&1; then
  LAN_IP="$(ipconfig getifaddr en0 2>/dev/null || ipconfig getifaddr en1 2>/dev/null || true)"
fi
TAILSCALE_IP=""
if command -v tailscale >/dev/null 2>&1; then
  TAILSCALE_IP="$(tailscale ip -4 2>/dev/null || true)"
fi
EXPO_HOST="${EXPO_HOST:-${LAN_IP:-$TAILSCALE_IP}}"
if [[ -n "$EXPO_HOST" ]]; then
  export REACT_NATIVE_PACKAGER_HOSTNAME="$EXPO_HOST"
fi

expo_url() {
  local host="$1"
  [[ -z "$host" ]] && return
  echo "exp://$host:$EXPO_PORT"
}

wait_for_metro() {
  local url="http://localhost:$EXPO_PORT/status"
  local start_time="$SECONDS"
  while (( SECONDS - start_time < EXPO_READY_TIMEOUT )); do
    if node -e '
      const http = require("node:http");
      const url = process.argv[1];
      const req = http.get(url, (res) => {
        let body = "";
        res.setEncoding("utf8");
        res.on("data", (chunk) => body += chunk);
        res.on("end", () => process.exit(res.statusCode === 200 && body.includes("packager-status:running") ? 0 : 1));
      });
      req.on("error", () => process.exit(1));
      req.setTimeout(1000, () => {
        req.destroy();
        process.exit(1);
      });
    ' "$url" >/dev/null 2>&1; then
      return 0
    fi
    sleep 1
  done
  return 1
}

cleanup() {
  [[ "${CLEANED_UP:-false}" == "true" ]] && return
  CLEANED_UP=true
  echo
  echo "正在停止 Cloudex 服务…"
  [[ -n "${SERVER_PID:-}" ]] && kill "$SERVER_PID" 2>/dev/null || true
  [[ -n "${MOBILE_PID:-}" ]] && kill "$MOBILE_PID" 2>/dev/null || true
  [[ -n "${MOBILE_TAIL_PID:-}" ]] && kill "$MOBILE_TAIL_PID" 2>/dev/null || true
}

trap cleanup EXIT
trap 'exit 130' INT TERM

cd "$PROJECT_DIR"

echo "==> 启动 API-only Codex App Server daemon"
if ! BOOTSTRAP_OUTPUT="$("$CODEX_BIN" app-server daemon bootstrap 2>&1)"; then
  echo "$BOOTSTRAP_OUTPUT"
  if [[ "$BOOTSTRAP_OUTPUT" == *"app server is running but is not managed by codex app-server daemon"* ]]; then
    echo "检测到 Codex app server 已经在运行，继续复用当前实例。"
  else
    exit 1
  fi
elif [[ -n "$BOOTSTRAP_OUTPUT" ]]; then
  echo "$BOOTSTRAP_OUTPUT"
fi

echo "==> 启动 Cloudex 服务器：http://$HOST:$PORT"
npm run server &
SERVER_PID=$!

echo "==> 启动 Expo 手机端（LAN 模式）"
EXPO_LOG_FILE="$(mktemp /tmp/cloudex-expo.XXXXXX)"
EXPO_ARGS=(start --lan --port "$EXPO_PORT")
if [[ "$EXPO_CLEAR_CACHE" == "true" ]]; then
  EXPO_ARGS+=(--clear)
fi
env \
  EXPO_NO_TELEMETRY="${EXPO_NO_TELEMETRY:-1}" \
  EXPO_USE_WATCHMAN="${EXPO_USE_WATCHMAN:-0}" \
  CI="$EXPO_CI_MODE" \
  npm --workspace @cloudex/mobile exec -- expo "${EXPO_ARGS[@]}" >"$EXPO_LOG_FILE" 2>&1 &
MOBILE_PID=$!
tail -n +1 -f "$EXPO_LOG_FILE" &
MOBILE_TAIL_PID=$!

if wait_for_metro; then
  echo "==> Expo/Metro 已就绪：http://localhost:$EXPO_PORT"
else
  echo "警告：等待 Expo/Metro 就绪超时，仍会打印二维码；如果扫码失败，请稍等几秒再扫或查看上方 Expo 日志。"
fi

echo
echo "手机设置："
echo "  服务器地址：http://<电脑的 Tailscale IP>:$PORT"
echo "  访问 Token：$AUTH_TOKEN"
LAN_EXPO_URL=""
TAILSCALE_EXPO_URL=""
if [[ -n "$TAILSCALE_IP" ]]; then
  echo "  Tailscale 服务器地址：http://$TAILSCALE_IP:$PORT"
  TAILSCALE_EXPO_URL="$(expo_url "$TAILSCALE_IP")"
fi
if [[ -n "$LAN_IP" ]]; then
  echo "  局域网服务器地址：http://$LAN_IP:$PORT"
  LAN_EXPO_URL="$(expo_url "$LAN_IP")"
fi
if [[ -n "$REACT_NATIVE_PACKAGER_HOSTNAME" ]]; then
  echo "  Expo manifest/bundle Host：$REACT_NATIVE_PACKAGER_HOSTNAME"
fi
if [[ -n "$LAN_EXPO_URL" ]]; then
  print_qr "  局域网二维码：$LAN_EXPO_URL" "$LAN_EXPO_URL"
fi
if [[ -n "$TAILSCALE_EXPO_URL" ]]; then
  print_qr "  Tailscale 二维码：$TAILSCALE_EXPO_URL" "$TAILSCALE_EXPO_URL"
fi
echo "按 Ctrl+C 同时停止服务器和 Expo。"

wait

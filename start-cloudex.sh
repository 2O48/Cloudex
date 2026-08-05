#!/usr/bin/env bash

set -euo pipefail

if [[ "${1:-}" == "--help" || "${1:-}" == "-h" ]]; then
  cat <<'EOF'
用法：
  npm run server
  ./start-cloudex.sh

可选环境变量：
  AUTH_TOKEN  API 访问 Bearer Token；省略时复用或生成临时 Token。
  HOST        Cloudex 监听地址，默认 0.0.0.0。
  PORT        Cloudex 监听端口，默认 8787。
  CODEX_BIN   Codex CLI 路径；默认使用 PATH 中的 codex。
EOF
  exit 0
fi

PROJECT_DIR="$(cd "$(dirname "$0")" && pwd)"
CODEX_BIN="${CODEX_BIN:-$(command -v codex 2>/dev/null || true)}"
CODEX_BIN="${CODEX_BIN:-$HOME/.codex/packages/standalone/current/bin/codex}"
HOST="${HOST:-0.0.0.0}"
PORT="${PORT:-8787}"
AUTH_TOKEN_FILE="${CLOUDEX_AUTH_TOKEN_FILE:-/tmp/cloudex-auth-token}"

if [[ ! -x "$CODEX_BIN" ]]; then
  echo "找不到 standalone Codex CLI：$CODEX_BIN" >&2
  echo "请先安装 Codex，或通过 CODEX_BIN 指定可执行文件路径。" >&2
  exit 1
fi

if [[ -z "${AUTH_TOKEN:-}" ]]; then
  if [[ -f "$AUTH_TOKEN_FILE" ]]; then
    AUTH_TOKEN="$(<"$AUTH_TOKEN_FILE")"
    echo "未设置 AUTH_TOKEN，已复用上次保存的 Token。"
  else
    umask 077
    AUTH_TOKEN="$(node -e 'console.log(require("node:crypto").randomBytes(24).toString("base64url"))')"
    printf '%s\n' "$AUTH_TOKEN" > "$AUTH_TOKEN_FILE"
    echo "未设置 AUTH_TOKEN，已生成并保存临时 Token。"
  fi
  export AUTH_TOKEN
fi

export HOST PORT AUTH_TOKEN CODEX_BIN

SERVER_PID=""
cleanup() {
  [[ -z "$SERVER_PID" ]] && return
  echo
  echo "正在停止 Cloudex 服务…"
  kill "$SERVER_PID" 2>/dev/null || true
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
echo "Cloudex API 已启动，按 Ctrl+C 停止。"
wait "$SERVER_PID"

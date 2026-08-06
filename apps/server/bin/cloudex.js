#!/usr/bin/env node
import crypto from "node:crypto";
import fs from "node:fs";
import fsp from "node:fs/promises";
import path from "node:path";
import { fileURLToPath } from "node:url";
import { execFile } from "node:child_process";
import { promisify } from "node:util";

const execFileAsync = promisify(execFile);
const packageRoot = path.join(path.dirname(fileURLToPath(import.meta.url)), "..");
const pkg = JSON.parse(fs.readFileSync(path.join(packageRoot, "package.json"), "utf8"));

function usage() {
  return `Cloudex CLI v${pkg.version} — 本地 Codex 控制服务器

用法:
  cloudex <command> [options]

命令:
  serve | start  启动 Cloudex 服务器（默认 http://0.0.0.0:8890）
  pair           打印手机端连接地址与扫码配对二维码
  about          查看本机环境、Codex CLI 与服务器状态
  version        显示版本号
  help           显示帮助

选项:
  --port <port>  覆盖监听端口（默认读取 PORT，或 8890）
  --host <host>  覆盖监听地址（默认读取 HOST，或 0.0.0.0）
  --json         about 命令输出 JSON，便于脚本使用
  -h, --help     显示帮助
  -v, --version  显示版本号

环境变量:
  AUTH_TOKEN / CLOUDEX_AUTH_TOKEN_FILE  认证 Token；未设置时自动生成并保存到 .cloudex-state/auth-token
  HOST / PORT / CODEX_BIN / FILE_ROOTS  与 start-cloudex.sh / start-cloudex.ps1 保持一致
  CLOUDEX_PUBLIC_URL                    手机端可访问的固定地址（二维码会优先使用它）

示例:
  cloudex pair
  cloudex about --json
  cloudex serve --host 0.0.0.0 --port 8890
`;
}

function parseArgs(argv) {
  const result = { command: null, port: null, host: null, json: false, help: false, version: false };
  const positionals = [];
  for (let index = 0; index < argv.length; index += 1) {
    const arg = argv[index];
    if (arg === "-h" || arg === "--help") result.help = true;
    else if (arg === "-v" || arg === "--version") result.version = true;
    else if (arg === "--json") result.json = true;
    else if (arg === "--port" || arg === "-p") result.port = argv[++index];
    else if (arg.startsWith("--port=")) result.port = arg.slice("--port=".length);
    else if (arg === "--host") result.host = argv[++index];
    else if (arg.startsWith("--host=")) result.host = arg.slice("--host=".length);
    else positionals.push(arg);
  }
  result.command = positionals[0] || null;
  return result;
}

function stateDir() {
  return process.env.CLOUDEX_STATE_DIR || path.join(process.cwd(), ".cloudex-state");
}

function tokenFilePath() {
  return process.env.CLOUDEX_AUTH_TOKEN_FILE || path.join(stateDir(), "auth-token");
}

function fileExists(file) {
  try {
    return fs.statSync(file).isFile();
  } catch {
    return false;
  }
}

function persistedToken() {
  try {
    return fs.readFileSync(tokenFilePath(), "utf8").trim() || null;
  } catch {
    return null;
  }
}

// 与 start-cloudex.sh / start-cloudex.ps1 保持一致：
// AUTH_TOKEN 未设置时，复用或生成项目内持久化的 Token，并写回环境变量。
async function ensureAuthTokenEnv() {
  if (process.env.AUTH_TOKEN) {
    return { token: process.env.AUTH_TOKEN, file: tokenFilePath(), source: "env" };
  }
  const file = tokenFilePath();
  try {
    const existing = (await fsp.readFile(file, "utf8")).trim();
    if (existing) {
      process.env.AUTH_TOKEN = existing;
      return { token: existing, file, source: "file" };
    }
  } catch {
    // Fall through: no persisted token yet.
  }
  const token = crypto.randomBytes(24).toString("base64url");
  await fsp.mkdir(path.dirname(file), { recursive: true });
  await fsp.writeFile(file, token, { encoding: "utf8", mode: 0o600 });
  process.env.AUTH_TOKEN = token;
  return { token, file, source: "created" };
}

function reportAuthSource(auth) {
  if (auth.source === "created") {
    console.log(`未设置 AUTH_TOKEN，已生成并保存到 ${auth.file}。`);
  } else if (auth.source === "file") {
    console.log(`未设置 AUTH_TOKEN，复用 ${auth.file}。`);
  }
}

async function detectCodexVersion(codexBin) {
  try {
    const { stdout } = await execFileAsync(codexBin, ["--version"], {
      timeout: 5000,
      windowsHide: true,
    });
    return String(stdout || "").trim() || null;
  } catch {
    return null;
  }
}

async function healthCheck(port, token) {
  try {
    const response = await fetch(`http://127.0.0.1:${port}/api/health`, {
      headers: token ? { authorization: `Bearer ${token}` } : undefined,
      signal: AbortSignal.timeout(1500),
    });
    if (response.ok) return true;
    // 401/403 说明端口上已经有需要认证的 Cloudex 服务在运行。
    return response.status === 401 || response.status === 403;
  } catch {
    return false;
  }
}

async function cmdPair() {
  const auth = await ensureAuthTokenEnv();
  reportAuthSource(auth);
  const { config } = await import("../src/config.js");
  const { printConnectionQRCode } = await import("../src/connection-qr.js");
  printConnectionQRCode({ host: config.host, port: config.port, authToken: config.authToken });
}

async function cmdAbout({ json }) {
  const { config } = await import("../src/config.js");
  const authFile = tokenFilePath();
  const info = {
    name: pkg.name,
    version: pkg.version,
    node: process.version,
    platform: `${process.platform} ${process.arch}`,
    machine: config.machine,
    codexBin: config.codexBin,
    codexExists: fileExists(config.codexBin),
    codexVersion: await detectCodexVersion(config.codexBin),
    controlSocket: config.controlSocketPath,
    controlSocketExists: fileExists(config.controlSocketPath),
    configFile: config.codexConfigPath,
    configFileExists: fileExists(config.codexConfigPath),
    sessionsDir: config.codexSessionsDir,
    sessionsDirExists: fileExists(config.codexSessionsDir),
    stateDir: config.stateDir,
    authFile,
    authEnabled: Boolean(process.env.AUTH_TOKEN || fileExists(authFile)),
    defaultUrl: `http://${config.host}:${config.port}`,
    serverRunning: await healthCheck(config.port, process.env.AUTH_TOKEN || persistedToken()),
  };

  if (json) {
    console.log(JSON.stringify(info, null, 2));
    return;
  }

  console.log(`Cloudex v${pkg.version}`);
  console.log(`  环境         ${info.platform}, 主机 ${info.machine}`);
  console.log(`  Node.js      ${info.node}`);
  console.log(
    `  Codex CLI    ${info.codexExists
      ? `${info.codexBin}${info.codexVersion ? ` (v${info.codexVersion})` : ""}`
      : `${info.codexBin}（未找到；请安装 standalone Codex CLI 或设置 CODEX_BIN）`}`,
  );
  console.log(`  控制 socket  ${info.controlSocket}${info.controlSocketExists ? "" : "（不存在）"}`);
  console.log(`  配置文件     ${info.configFile}${info.configFileExists ? "" : "（不存在）"}`);
  console.log(`  会话目录     ${info.sessionsDir}${info.sessionsDirExists ? "" : "（不存在）"}`);
  console.log(`  状态目录     ${info.stateDir}`);
  console.log(`  默认地址     ${info.defaultUrl}`);
  console.log(`  服务器状态   ${info.serverRunning ? "运行中" : "未运行（127.0.0.1 健康检查失败）"}`);
  console.log(`  HTTP 认证    ${info.authEnabled ? "Bearer token 已启用" : "未启用（仅限本机访问）"}`);
}

async function cmdServe() {
  const auth = await ensureAuthTokenEnv();
  reportAuthSource(auth);
  console.log("正在启动 Cloudex 服务器；若 Codex app-server 未就绪，会自动重试（最长约 30 秒）后以本地历史模式继续。");
  const { startServer } = await import("../src/server.js");
  await startServer();
}

async function main() {
  const { command, port, host, json, help, version } = parseArgs(process.argv.slice(2));
  if (port) process.env.PORT = String(port);
  if (host) process.env.HOST = host;

  if (version || command === "version") {
    console.log(pkg.version);
    return;
  }
  if (help || command === "help" || !command) {
    console.log(usage());
    return;
  }

  if (command === "serve" || command === "start") await cmdServe();
  else if (command === "pair") await cmdPair();
  else if (command === "about") await cmdAbout({ json });
  else {
    console.error(`未知命令：${command}\n`);
    console.error(usage());
    process.exitCode = 1;
  }
}

main().catch((error) => {
  console.error(error?.message || error);
  process.exitCode = 1;
});

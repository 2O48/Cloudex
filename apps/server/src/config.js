import os from "node:os";
import path from "node:path";
import crypto from "node:crypto";
import fs from "node:fs";

const standaloneCodexBin = path.join(os.homedir(), ".codex", "packages", "standalone", "current", "bin", "codex");
function codexFromPath() {
  const executable = process.platform === "win32" ? "codex.exe" : "codex";
  for (const directory of (process.env.PATH || "").split(path.delimiter)) {
    if (!directory) continue;
    const candidate = path.join(directory, executable);
    try {
      fs.accessSync(candidate, fs.constants.X_OK);
      return candidate;
    } catch {}
  }
  return null;
}
function windowsCodexBin() {
  if (process.platform !== "win32") return null;
  const root = path.join(os.homedir(), "AppData", "Local", "OpenAI", "Codex", "bin");
  try {
    return fs.readdirSync(root, { withFileTypes: true })
      .filter((entry) => entry.isDirectory())
      .map((entry) => path.join(root, entry.name, "codex.exe"))
      .filter((candidate) => fs.existsSync(candidate))
      .sort((left, right) => fs.statSync(right).mtimeMs - fs.statSync(left).mtimeMs)[0] || null;
  } catch {
    return null;
  }
}

const defaultCodexBin = process.env.CODEX_BIN
  || codexFromPath()
  || (fs.existsSync(standaloneCodexBin) ? standaloneCodexBin : null)
  // Desktop exports CODEX_CLI_PATH into child shells. Keep it as a final
  // fallback so a real CLI on PATH remains authoritative for Cloudex.
  || process.env.CODEX_CLI_PATH
  || windowsCodexBin()
  || "codex";

const host = process.env.HOST || "0.0.0.0";
const authToken = process.env.AUTH_TOKEN || "";
const fileRoots = (process.env.FILE_ROOTS || process.cwd())
  .split(path.delimiter)
  .map((item) => path.resolve(item))
  .filter(Boolean);

export const config = {
  host,
  port: Number(process.env.PORT || 8890),
  authToken,
  codexBin: process.env.CODEX_BIN || defaultCodexBin,
  codexConfigPath: process.env.CODEX_CONFIG_PATH
    || path.join(os.homedir(), ".codex", "config.toml"),
  historySource: process.env.CLOUDEX_HISTORY_SOURCE || "cli-local",
  includeSubagents: process.env.CLOUDEX_INCLUDE_SUBAGENTS === "true",
  activeStaleSeconds: Number(process.env.CLOUDEX_ACTIVE_STALE_SECONDS || 4 * 60 * 60),
  codexSessionsDir: process.env.CODEX_SESSIONS_DIR
    || path.join(os.homedir(), ".codex", "sessions"),
  stateDir: process.env.CLOUDEX_STATE_DIR || path.join(process.cwd(), ".cloudex-state"),
  controlSocketPath: process.env.CODEX_CONTROL_SOCKET
    || path.join(os.homedir(), ".codex", "app-server-control", "app-server-control.sock"),
  fileRoots,
  defaultCwd: path.resolve(process.env.DEFAULT_CWD || process.cwd()),
  isLoopback: host === "127.0.0.1" || host === "localhost" || host === "::1",
  nodeVersion: process.version,
  machine: os.hostname(),
};

export function createDevToken() {
  return crypto.randomBytes(18).toString("base64url");
}

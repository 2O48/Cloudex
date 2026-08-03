import os from "node:os";
import path from "node:path";
import crypto from "node:crypto";
import fs from "node:fs";

const standaloneCodexBin = path.join(os.homedir(), ".codex", "packages", "standalone", "current", "codex");
const defaultCodexBin = fs.existsSync(standaloneCodexBin)
  ? standaloneCodexBin
  : "codex";

const host = process.env.HOST || "127.0.0.1";
const authToken = process.env.AUTH_TOKEN || "";
const fileRoots = (process.env.FILE_ROOTS || process.cwd())
  .split(path.delimiter)
  .map((item) => path.resolve(item))
  .filter(Boolean);

export const config = {
  host,
  port: Number(process.env.PORT || 8787),
  authToken,
  codexBin: process.env.CODEX_BIN || defaultCodexBin,
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

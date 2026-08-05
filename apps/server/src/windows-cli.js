import fs from "node:fs/promises";
import { spawn } from "node:child_process";
import { config } from "./config.js";
import { CodexError } from "./codex-client.js";
import { findSessionFiles, readCliThreadById, threadIdFromPath } from "./cli-sessions.js";

const NEW_SESSION_TIMEOUT_MS = 60_000;
const TURN_TIMEOUT_MS = 30_000;
const POLL_INTERVAL_MS = 250;
const RUNNING_CHILDREN = new Map();

function sleep(ms) {
  return new Promise((resolve) => setTimeout(resolve, ms));
}

function log(...args) {
  console.log("[windows-cli]", ...args);
}

export function isWindowsPlatform() {
  return process.platform === "win32";
}

export function buildCliArgs({
  resume = false,
  threadId = null,
  cwd = null,
  prompt = null,
  files = [],
  model = null,
  effort = null,
  sandbox = null,
  approvalPolicy = null,
} = {}) {
  const args = resume ? ["exec", "resume", "--json"] : ["exec", "--json"];
  if (resume) {
    if (threadId) args.push(threadId);
  } else if (cwd) {
    args.push("-C", cwd);
  }
  if (model) args.push("-m", model);
  if (effort) args.push("-c", `model_reasoning_effort="${effort}"`);
  if (sandbox) args.push("-c", `sandbox_mode="${sandbox}"`);
  if (approvalPolicy) args.push("-c", `approval_policy="${approvalPolicy}"`);
  for (const file of files) {
    const filePath = typeof file === "string" ? file : file?.path;
    if (filePath) args.push("-i", filePath);
  }
  if (prompt) args.push(prompt);
  return args;
}

function spawnCli(args, spawnCwd) {
  const child = spawn(config.codexBin, args, {
    cwd: spawnCwd || config.defaultCwd,
    stdio: ["ignore", "pipe", "pipe"],
    windowsHide: true,
    env: process.env,
  });
  let stderrText = "";
  child.stderr.on("data", (chunk) => {
    const text = chunk.toString();
    stderrText += text;
    log("stderr:", text.trim());
  });
  child.stdout.on("data", (chunk) => {
    const line = chunk.toString().trim().split("\n")[0];
    if (line) log("stdout:", line.slice(0, 300));
  });
  return { child, stderr: () => stderrText };
}

function monitorExit(child) {
  let result = null;
  child.once("exit", (code, signal) => {
    result = { code, signal };
  });
  return () => result;
}

async function waitForNewSession(before, timeoutMs) {
  const deadline = Date.now() + timeoutMs;
  while (Date.now() < deadline) {
    const files = await findSessionFiles();
    const candidates = files.filter((file) => !before.has(file));
    if (candidates.length > 0) {
      const stats = await Promise.all(candidates.map(async (file) => ({
        file,
        stat: await fs.stat(file).catch(() => null),
      })));
      const newest = stats
        .filter((entry) => entry.stat)
        .sort((left, right) => right.stat.mtimeMs - left.stat.mtimeMs)[0];
      if (newest) return threadIdFromPath(newest.file);
    }
    await sleep(POLL_INTERVAL_MS);
  }
  return null;
}

async function waitForNewTurn(threadId, baselineIds, timeoutMs) {
  const deadline = Date.now() + timeoutMs;
  while (Date.now() < deadline) {
    try {
      const { turns } = await readCliThreadById(threadId);
      const latest = turns[turns.length - 1];
      if (latest && !baselineIds.has(latest.id)) return latest;
    } catch {
      // The session file may not be parseable yet; keep polling.
    }
    await sleep(POLL_INTERVAL_MS);
  }
  return null;
}

function trackChild(threadId, child) {
  RUNNING_CHILDREN.set(threadId, child);
  child.once("exit", () => RUNNING_CHILDREN.delete(threadId));
}

export async function startNewThread({
  cwd,
  prompt,
  files = [],
  model = null,
  effort = null,
  sandbox = null,
  approvalPolicy = null,
} = {}) {
  if (!prompt) {
    const error = new Error("prompt is required on Windows CLI mode");
    error.status = 422;
    throw error;
  }
  const before = new Set(await findSessionFiles());
  const args = buildCliArgs({
    resume: false,
    cwd,
    prompt,
    files,
    model,
    effort,
    sandbox,
    approvalPolicy,
  });
  const { child, stderr } = spawnCli(args, cwd);
  const exited = monitorExit(child);
  const threadId = await waitForNewSession(before, NEW_SESSION_TIMEOUT_MS);
  if (!threadId) {
    child.kill();
    throw new CodexError(`Timed out waiting for a new Codex session${stderr() ? `: ${stderr()}` : ""}`);
  }
  const turn = await waitForNewTurn(threadId, new Set(), TURN_TIMEOUT_MS);
  const exit = exited();
  if (exit && exit.code !== 0) {
    throw new CodexError(`Codex CLI exited (${exit.code ?? exit.signal}) while starting a session: ${stderr()}`);
  }
  if (!turn) {
    child.kill();
    throw new CodexError(`Timed out waiting for the first turn${stderr() ? `: ${stderr()}` : ""}`);
  }
  trackChild(threadId, child);
  return threadId;
}

export async function resumeThread({
  threadId,
  prompt,
  files = [],
  model = null,
  effort = null,
  sandbox = null,
  approvalPolicy = null,
} = {}) {
  let detail;
  try {
    detail = await readCliThreadById(threadId);
  } catch (error) {
    throw new CodexError(`Session ${threadId} was not found: ${error.message}`, { status: 404 });
  }
  const baselineIds = new Set((detail.turns || []).map((turn) => turn.id));
  const args = buildCliArgs({
    resume: true,
    threadId,
    prompt,
    files,
    model,
    effort,
    sandbox,
    approvalPolicy,
  });
  const { child, stderr } = spawnCli(args, detail.thread?.cwd || config.defaultCwd);
  const exited = monitorExit(child);
  const turn = await waitForNewTurn(threadId, baselineIds, TURN_TIMEOUT_MS);
  const exit = exited();
  if (exit && exit.code !== 0) {
    throw new CodexError(`Codex CLI exited (${exit.code ?? exit.signal}) before the turn started: ${stderr()}`);
  }
  if (!turn) {
    child.kill();
    throw new CodexError(`Timed out waiting for the resumed turn to start${stderr() ? `: ${stderr()}` : ""}`);
  }
  trackChild(threadId, child);
  return { turnId: turn.id };
}

export function stopThread(threadId) {
  const child = RUNNING_CHILDREN.get(threadId);
  if (!child || child.exitCode !== null || child.signalCode !== null) return false;
  try {
    const killer = spawn("taskkill", ["/PID", String(child.pid), "/T", "/F"], {
      windowsHide: true,
      stdio: "ignore",
    });
    killer.unref();
  } catch {
    // Fall through: the process may already be gone.
  }
  RUNNING_CHILDREN.delete(threadId);
  return true;
}

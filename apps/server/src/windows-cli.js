import fs from "node:fs/promises";
import { spawn } from "node:child_process";
import { config } from "./config.js";
import { CodexError } from "./codex-client.js";
import {
  commandActivity,
  findSessionFiles,
  readCliThreadById,
  threadIdFromPath,
} from "./cli-sessions.js";

const NEW_SESSION_TIMEOUT_MS = 60_000;
const TURN_TIMEOUT_MS = 30_000;
const POLL_INTERVAL_MS = 250;
const RUNNING_CHILDREN = new Map();

function sleep(ms) {
  return new Promise((resolve) => setTimeout(resolve, ms));
}

const ITEM_TYPE_MAP = {
  command_execution: "commandExecution",
  agent_message: "agentMessage",
  file_change: "fileChange",
  reasoning: "reasoning",
  web_search: "webSearch",
  mcp_tool_call: "mcpToolCall",
  collab_tool_call: "collabToolCall",
  todo_list: "todoList",
  error: "error",
};

function camelize(value) {
  return String(value || "").replace(/_([a-z])/g, (_, letter) => letter.toUpperCase());
}

function appStatus(status) {
  const value = camelize(status);
  return value || "inProgress";
}

function usageToApp(usage) {
  if (!usage || typeof usage !== "object") return null;
  const result = {};
  for (const [key, value] of Object.entries(usage)) {
    result[camelize(key)] = value;
  }
  return result;
}

function itemMethodForEventType(type) {
  if (type === "item.started") return "item/started";
  if (type === "item.updated") return "item/updated";
  return "item/completed";
}

export function execItemToAppItem(raw) {
  if (!raw || typeof raw !== "object") return null;
  const rawType = String(raw.type || "");
  const type = ITEM_TYPE_MAP[rawType] || camelize(rawType);
  const base = { id: raw.id, type };
  if (rawType === "command_execution") {
    const command = String(raw.command || "").trim();
    const item = {
      ...base,
      command,
      activity: commandActivity(command),
      status: appStatus(raw.status),
      exitCode: typeof raw.exit_code === "number" ? raw.exit_code : null,
    };
    if (typeof raw.duration_ms === "number") item.durationMs = raw.duration_ms;
    if (raw.aggregated_output) item.aggregatedOutput = String(raw.aggregated_output);
    return item;
  }
  if (rawType === "file_change") {
    return {
      ...base,
      changes: Array.isArray(raw.changes)
        ? raw.changes.map((change) => ({ path: change?.path, kind: change?.kind }))
        : [],
      activity: "edited",
      status: appStatus(raw.status),
    };
  }
  if (rawType === "agent_message") {
    return { ...base, text: String(raw.text || "") };
  }
  if (rawType === "error") {
    return { ...base, message: String(raw.message || "") };
  }
  return base;
}

export function execEventToAppMessage(event, { threadId = null, turnId = null } = {}) {
  if (!event || typeof event !== "object") return null;
  const params = { threadId };
  switch (event.type) {
    case "thread.started":
      return {
        method: "thread/started",
        params: {
          threadId: threadId || event.thread_id || null,
          thread: { id: threadId || event.thread_id || null },
        },
      };
    case "turn.started":
      return { method: "turn/started", params: { ...params, turnId, turn: { id: turnId } } };
    case "turn.completed":
      return {
        method: "turn/completed",
        params: {
          ...params,
          turnId,
          turn: { id: turnId, status: "completed" },
          usage: usageToApp(event.usage),
        },
      };
    case "turn.failed":
      return {
        method: "turn/failed",
        params: {
          ...params,
          turnId,
          turn: {
            id: turnId,
            status: "failed",
            error: event.error || { message: "Turn failed" },
          },
          error: event.error || { message: "Turn failed" },
        },
      };
    case "error":
      return {
        method: "turn/failed",
        params: {
          ...params,
          turnId,
          turn: {
            id: turnId,
            status: "failed",
            error: { message: event.message || "Codex stream error" },
          },
          error: event.message || "Codex stream error",
        },
      };
    case "item.started":
    case "item.updated":
    case "item.completed": {
      const item = execItemToAppItem(event.item);
      if (!item) return null;
      return {
        method: itemMethodForEventType(event.type),
        params: { ...params, turnId, itemId: item.id, item },
      };
    }
    default:
      return null;
  }
}

let syntheticTurnCounter = 0;
const TURN_ID_FALLBACK_MS = 10_000;

function syntheticTurnId(threadId) {
  syntheticTurnCounter += 1;
  return `win-turn-${String(threadId || "x").slice(0, 8)}-${Date.now().toString(36)}-${syntheticTurnCounter}`;
}

function createExecEventBridge(onAppMessage, resolveTurnId) {
  const buffer = [];
  let threadId = null;
  let turnId = null;
  let turnIdPromise = null;
  let turnIdFallbackTimer = null;

  function flush() {
    while (buffer.length > 0) {
      const [pendingEvent] = buffer.shift();
      const message = execEventToAppMessage(pendingEvent, { threadId, turnId });
      if (message && onAppMessage) onAppMessage(message);
    }
  }

  function ensureTurnId() {
    if (turnId || turnIdPromise) return;
    if (!resolveTurnId) {
      turnId = syntheticTurnId(threadId || "new");
      flush();
      return;
    }
    turnIdPromise = Promise.resolve()
      .then(() => resolveTurnId(threadId))
      .then((resolved) => {
        if (turnId) return; // The fallback timer already flushed.
        clearTimeout(turnIdFallbackTimer);
        turnId = resolved || syntheticTurnId(threadId || "new");
        turnIdPromise = null;
        flush();
      })
      .catch(() => {
        if (turnId) return;
        clearTimeout(turnIdFallbackTimer);
        turnId = syntheticTurnId(threadId || "new");
        turnIdPromise = null;
        flush();
      });
    turnIdFallbackTimer = setTimeout(() => {
      if (turnId) return;
      turnId = syntheticTurnId(threadId || "new");
      turnIdPromise = null;
      flush();
    }, TURN_ID_FALLBACK_MS);
  }

  function needsTurnId(eventType) {
    return eventType === "turn.started"
      || eventType === "turn.completed"
      || eventType === "turn.failed"
      || eventType === "error"
      || eventType.startsWith("item.");
  }

  function handleEvent(event) {
    if (!onAppMessage) return;
    if (event.type === "thread.started" && typeof event.thread_id === "string") {
      threadId = event.thread_id;
      flush();
    }
    if (event.type === "turn.started") ensureTurnId();
    if (!threadId || (needsTurnId(event.type) && !turnId)) {
      buffer.push([event]);
      return;
    }
    const message = execEventToAppMessage(event, { threadId, turnId });
    if (message) onAppMessage(message);
  }

  return {
    handleEvent,
    setThreadId(value) {
      if (!value || threadId) return;
      threadId = value;
      flush();
    },
    getThreadId() {
      return threadId;
    },
  };
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

function spawnCli(args, spawnCwd, { onExecEvent = null } = {}) {
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
  });
  let stdoutBuffer = "";
  child.stdout.on("data", (chunk) => {
    stdoutBuffer += chunk.toString();
    let newlineIndex;
    while ((newlineIndex = stdoutBuffer.indexOf("\n")) >= 0) {
      const line = stdoutBuffer.slice(0, newlineIndex).trim();
      stdoutBuffer = stdoutBuffer.slice(newlineIndex + 1);
      if (!line) continue;
      if (!onExecEvent) continue;
      let event;
      try {
        event = JSON.parse(line);
      } catch {
        continue;
      }
      if (event && typeof event.type === "string") onExecEvent(event);
    }
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
  onAppMessage = null,
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
  let turnPromise = null;
  const bridge = createExecEventBridge(onAppMessage, (turnThreadId) => {
    if (!turnThreadId) return Promise.resolve(null);
    if (!turnPromise) turnPromise = waitForNewTurn(turnThreadId, new Set(), TURN_TIMEOUT_MS);
    return turnPromise.then((turn) => turn?.id || null);
  });
  const { child, stderr } = spawnCli(args, cwd, { onExecEvent: bridge.handleEvent });
  const exited = monitorExit(child);
  const threadId = await waitForNewSession(before, NEW_SESSION_TIMEOUT_MS);
  bridge.setThreadId(threadId);
  if (!threadId) {
    child.kill();
    throw new CodexError(`Timed out waiting for a new Codex session${stderr() ? `: ${stderr()}` : ""}`);
  }
  const turn = await (turnPromise || waitForNewTurn(threadId, new Set(), TURN_TIMEOUT_MS));
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
  onAppMessage = null,
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
  let turnPromise = null;
  const bridge = createExecEventBridge(onAppMessage, (turnThreadId) => {
    if (!turnThreadId) return Promise.resolve(null);
    if (!turnPromise) turnPromise = waitForNewTurn(turnThreadId, baselineIds, TURN_TIMEOUT_MS);
    return turnPromise.then((turn) => turn?.id || null);
  });
  bridge.setThreadId(threadId);
  const { child, stderr } = spawnCli(args, detail.thread?.cwd || config.defaultCwd, {
    onExecEvent: bridge.handleEvent,
  });
  const exited = monitorExit(child);
  const turn = await (turnPromise || waitForNewTurn(threadId, baselineIds, TURN_TIMEOUT_MS));
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

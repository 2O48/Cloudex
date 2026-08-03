import http from "node:http";
import os from "node:os";
import fs from "node:fs/promises";
import path from "node:path";
import { config } from "./config.js";
import { CodexClient, CodexError } from "./codex-client.js";
import { archiveCliThread, listCliThreads, readCliThreadById } from "./cli-sessions.js";

const client = new CodexClient();
const subscribers = new Map();
const globalSubscribers = new Set();
const eventHistory = new Map();
const pendingApprovals = new Map();
const EVENT_HISTORY_LIMIT = 250;
const MODELS_CACHE_FILE = process.env.CLOUDEX_MODELS_CACHE
  || path.join(os.homedir(), ".codex", "models_cache.json");
let eventSequence = 0;
let latestThreadSignature = "";
let latestProjectSnapshot = null;
let syncInFlight = false;
let syncAgainReason = null;
let syncTimer = null;
let syncInterval = null;

function normalizeModel(model) {
  const id = model?.id || model?.model || model?.slug;
  if (!id) return null;
  const rawLevels = model.supportedReasoningEfforts
    || model.supportedReasoningLevels
    || model.supported_reasoning_levels
    || [];
  const supportedReasoningEfforts = rawLevels
    .map((level) => {
      if (typeof level === "string") return { reasoningEffort: level, description: null };
      const reasoningEffort = level?.reasoningEffort || level?.effort || level?.reasoning_level || level?.level;
      return reasoningEffort
        ? { reasoningEffort, description: level.description || null }
        : null;
    })
    .filter(Boolean);
  const supportedReasoningLevels = supportedReasoningEfforts.map(({ reasoningEffort, description }) => ({
    effort: reasoningEffort,
    description,
  }));
  const defaultReasoningEffort = model.defaultReasoningEffort
    || model.defaultReasoningLevel
    || model.default_reasoning_level
    || supportedReasoningEfforts[0]?.reasoningEffort
    || null;
  return {
    ...model,
    id,
    model: model.model || id,
    displayName: model.displayName || model.display_name || id,
    defaultReasoningLevel: defaultReasoningEffort,
    supportedReasoningLevels,
    defaultReasoningEffort,
    supportedReasoningEfforts,
    hidden: model.hidden ?? model.visibility === "hide",
  };
}

function normalizeModelsResponse(result) {
  return {
    ...result,
    data: (result?.data || []).map(normalizeModel).filter(Boolean),
  };
}

async function readCachedModels() {
  try {
    const payload = JSON.parse(await fs.readFile(MODELS_CACHE_FILE, "utf8"));
    const data = (payload.models || [])
      .filter((model) => model?.visibility !== "hide" && model?.supported_in_api !== false)
      .map(normalizeModel)
      .filter(Boolean);
    if (data.length === 0) return null;
    return {
      data,
      nextCursor: null,
      source: "local-cache",
      cachedAt: payload.fetched_at || null,
    };
  } catch {
    return null;
  }
}

async function listModels() {
  if (!client.socket || client.socket.closed) {
    const cached = await readCachedModels();
    if (cached) return cached;
  }
  try {
    return normalizeModelsResponse(await client.request("model/list", { limit: 100 }));
  } catch (error) {
    const cached = await readCachedModels();
    if (cached) return cached;
    throw error;
  }
}

function json(res, status, body) {
  res.writeHead(status, {
    "content-type": "application/json; charset=utf-8",
    "cache-control": "no-store",
    "access-control-allow-origin": "*",
  });
  res.end(JSON.stringify(body));
}

function errorResponse(res, error) {
  const status = error.status || (error instanceof CodexError ? 502 : 400);
  json(res, status, { error: error.message || "Request failed" });
}

function isImage(filePath) {
  return /\.(png|jpe?g|gif|webp|bmp|svg)$/i.test(filePath);
}

function normalizePath(candidate) {
  const resolved = path.resolve(candidate || config.defaultCwd);
  const allowed = config.fileRoots.some((root) => resolved === root || resolved.startsWith(`${root}${path.sep}`));
  if (!allowed) {
    const error = new Error("Path is outside FILE_ROOTS");
    error.status = 403;
    throw error;
  }
  return resolved;
}

function authOk(req, url) {
  if (!config.authToken) return config.isLoopback;
  const header = req.headers.authorization;
  const queryToken = url.searchParams.get("token");
  return header === `Bearer ${config.authToken}` || queryToken === config.authToken;
}

function body(req) {
  return new Promise((resolve, reject) => {
    let value = "";
    req.on("data", (chunk) => {
      value += chunk;
      if (value.length > 1024 * 1024) reject(new Error("Request body too large"));
    });
    req.on("end", () => {
      if (!value) return resolve({});
      try { resolve(JSON.parse(value)); } catch { reject(new Error("Request body must be valid JSON")); }
    });
    req.on("error", reject);
  });
}

function getThreadId(message) {
  const params = message.params || {};
  return params.threadId || params.thread?.id || params.turn?.threadId || null;
}

function writeSse(res, event, data, id = null) {
  res.write(`${id === null ? "" : `id: ${id}\n`}event: ${event}\ndata: ${JSON.stringify(data)}\n\n`);
}

function broadcastGlobal(event, data) {
  for (const res of globalSubscribers) writeSse(res, event, data);
}

function remember(message) {
  const threadId = getThreadId(message);
  if (!threadId) return null;
  const history = eventHistory.get(threadId) || [];
  const record = { id: ++eventSequence, message };
  history.push(record);
  if (history.length > EVENT_HISTORY_LIMIT) history.splice(0, history.length - EVENT_HISTORY_LIMIT);
  eventHistory.set(threadId, history);
  return record;
}

function publish(message) {
  const threadId = getThreadId(message);
  const record = remember(message);
  // Keep the global bus lossless so other local clients (including a CLI
  // bridge) can observe the same live tool progress as thread subscribers.
  broadcastGlobal("notification", message);
  if ([
    "thread/started",
    "thread/archived",
    "thread/name/updated",
    "turn/started",
    "turn/completed",
    "turn/failed",
    "turn/interrupted",
    "turn/cancelled",
    "turn/canceled",
  ].includes(message.method)) {
    scheduleThreadSync(`notification:${message.method}`, 200);
  }
  if (!threadId || !subscribers.has(threadId)) return;
  for (const res of subscribers.get(threadId)) {
    writeSse(res, "notification", message, record.id);
    if (message.method === "item/agentMessage/delta") {
      writeSse(res, "delta", { delta: message.params?.delta || "", raw: message }, record.id);
    }
  }
}

client.on("notification", publish);

function approvalFromRequest(message) {
  if (![
    "item/commandExecution/requestApproval",
    "item/fileChange/requestApproval",
    "item/permissions/requestApproval",
  ].includes(message.method)) return null;
  const params = message.params || {};
  const command = Array.isArray(params.command) ? params.command.join(" ") : params.command;
  const availableDecisions = Array.isArray(params.availableDecisions)
    ? params.availableDecisions.filter((value) => typeof value === "string")
    : [];
  const permissionSummary = [];
  if (params.permissions?.network?.enabled) permissionSummary.push("访问网络");
  const fileSystem = params.permissions?.fileSystem;
  if (fileSystem?.write?.length || fileSystem?.entries?.some((entry) => entry?.access === "write")) permissionSummary.push("写入额外文件路径");
  if (fileSystem?.read?.length || fileSystem?.entries?.some((entry) => entry?.access === "read")) permissionSummary.push("读取额外文件路径");
  return {
    id: String(message.id),
    method: message.method,
    threadId: params.threadId || null,
    turnId: params.turnId || null,
    itemId: params.itemId || null,
    reason: params.reason || null,
    command: command || null,
    cwd: params.cwd || null,
    grantRoot: params.grantRoot || null,
    commandActions: params.commandActions || null,
    networkApprovalContext: params.networkApprovalContext || null,
    availableDecisions: availableDecisions.length > 0 ? availableDecisions : ["accept", "acceptForSession", "decline"],
    permissionSummary: permissionSummary.join("、") || null,
    requestedAt: Date.now(),
  };
}

client.on("serverRequest", (message) => {
  const approval = approvalFromRequest(message);
  if (!approval) return;
  pendingApprovals.set(approval.id, { approval, rpcId: message.id, requestParams: message.params || {} });
  console.log(`Cloudex approval requested: ${approval.method} (${approval.id})`);
  broadcastGlobal("approval/requested", approval);
});

client.on("notification", (message) => {
  if (message.method !== "serverRequest/resolved") return;
  const requestId = message.params?.requestId;
  if (requestId === undefined) return;
  const id = String(requestId);
  if (!pendingApprovals.delete(id)) return;
  broadcastGlobal("approval/resolved", { id, threadId: message.params?.threadId || null });
});

function subscribe(threadId, res) {
  if (!subscribers.has(threadId)) subscribers.set(threadId, new Set());
  subscribers.get(threadId).add(res);
  const cleanup = () => {
    subscribers.get(threadId)?.delete(res);
    if (subscribers.get(threadId)?.size === 0) subscribers.delete(threadId);
  };
  res.on("close", cleanup);
  return cleanup;
}

function subscribeGlobal(res) {
  globalSubscribers.add(res);
  const cleanup = () => globalSubscribers.delete(res);
  res.on("close", cleanup);
  return cleanup;
}

function replayEvents(threadId, res) {
  for (const record of eventHistory.get(threadId) || []) {
    const { message } = record;
    writeSse(res, "notification", message, record.id);
    if (message.method === "item/agentMessage/delta") {
      writeSse(res, "delta", { delta: message.params?.delta || "", raw: message }, record.id);
    }
  }
}

async function fileListing(url) {
  const dir = normalizePath(url.searchParams.get("path"));
  const entries = await fs.readdir(dir, { withFileTypes: true });
  return Promise.all(entries
    .filter((entry) => !entry.name.startsWith("."))
    .sort((a, b) => Number(b.isDirectory()) - Number(a.isDirectory()) || a.name.localeCompare(b.name))
    .map(async (entry) => {
      const filePath = path.join(dir, entry.name);
      const metadata = entry.isDirectory() ? null : await fs.stat(filePath);
      return {
        name: entry.name,
        path: filePath,
        type: entry.isDirectory() ? "directory" : "file",
        size: metadata?.size ?? null,
        modifiedAt: metadata?.mtime.toISOString() ?? null,
        selectable: true,
      };
    }));
}

async function listAllThreads(archived = false) {
  if (config.historySource === "cli-local") return listCliThreads({ archived });
  const threads = [];
  let cursor = null;
  do {
    const result = await client.request("thread/list", {
      limit: 100,
      archived,
      cursor,
      sortDirection: "desc",
    });
    threads.push(...(result.data || []));
    cursor = result.nextCursor || null;
  } while (cursor);
  return threads;
}

async function readThreadDetail(threadId) {
  if (config.historySource === "cli-local") return readCliThreadById(threadId);
  const result = await client.request("thread/read", { threadId, includeTurns: true });
  const thread = result.thread || result;
  return { thread, turns: thread.turns || [] };
}

function projectsFromThreads(threads) {
  const projects = new Map();
  for (const thread of threads) {
    const cwd = thread.cwd || "未指定项目目录";
    if (!projects.has(cwd)) {
      projects.set(cwd, {
        id: cwd,
        name: path.basename(cwd) || cwd,
        cwd,
        threads: [],
        updatedAt: thread.updatedAt || thread.createdAt || 0,
      });
    }
    const project = projects.get(cwd);
    project.threads.push(thread);
    project.updatedAt = Math.max(project.updatedAt, thread.updatedAt || thread.createdAt || 0);
  }
  return [...projects.values()].sort((a, b) => b.updatedAt - a.updatedAt);
}

function threadSignature(threads) {
  return JSON.stringify(threads.map((thread) => ({
    id: thread.id,
    cwd: thread.cwd || "",
    name: thread.name || "",
    preview: thread.preview || "",
    updatedAt: thread.updatedAt || 0,
    syncRevision: thread.syncRevision || "",
    status: thread.status?.type || "",
    activeFlags: thread.status?.activeFlags || [],
  })));
}

function snapshotFromThreads(threads) {
  return {
    generatedAt: Date.now(),
    projects: projectsFromThreads(threads),
    total: threads.length,
  };
}

function scheduleThreadSync(reason = "manual", delay = 0) {
  if (syncTimer) clearTimeout(syncTimer);
  syncTimer = setTimeout(() => {
    syncTimer = null;
    syncThreads(reason).catch((error) => console.warn(`Cloudex sync failed: ${error.message}`));
  }, delay);
}

async function syncThreads(reason = "manual") {
  if (syncInFlight) {
    syncAgainReason = reason;
    return;
  }
  syncInFlight = true;
  try {
    const threads = await listAllThreads(false);
    const runningThreads = threads.filter((thread) => thread.status?.type === "active");
    await Promise.allSettled(runningThreads.map((thread) => client.subscribeThread(thread.id)));
    const signature = threadSignature(threads);
    if (signature !== latestThreadSignature) {
      latestThreadSignature = signature;
      latestProjectSnapshot = snapshotFromThreads(threads);
      broadcastGlobal("threads/changed", { reason, ...latestProjectSnapshot });
    }
  } finally {
    syncInFlight = false;
    if (syncAgainReason) {
      const nextReason = syncAgainReason;
      syncAgainReason = null;
      scheduleThreadSync(nextReason, 100);
    }
  }
}

function startThreadSync() {
  scheduleThreadSync("startup", 0);
  syncInterval = setInterval(() => scheduleThreadSync("poll", 0), 1000);
}

function stopThreadSync() {
  if (syncTimer) clearTimeout(syncTimer);
  if (syncInterval) clearInterval(syncInterval);
  syncTimer = null;
  syncInterval = null;
}

async function normalizeThreadCwd(candidate) {
  const resolved = path.resolve(candidate || config.defaultCwd);
  try {
    return normalizePath(resolved);
  } catch (error) {
    if (error.status !== 403) throw error;
    const knownThreads = await listAllThreads(false);
    if (knownThreads.some((thread) => thread.cwd && path.resolve(thread.cwd) === resolved)) return resolved;
    throw error;
  }
}

function inputFrom(bodyData) {
  const message = String(bodyData.message || "").trim();
  if (!message) {
    const error = new Error("message is required");
    error.status = 422;
    throw error;
  }
  const input = [{ type: "text", text: message }];
  for (const file of bodyData.files || []) {
    const filePath = normalizePath(file.path || file);
    if (isImage(filePath)) input.push({ type: "localImage", path: filePath });
    else input[0].text += `\n\n[Attached local file: ${filePath}]`;
  }
  return input;
}

function isUnfinishedTurn(turn) {
  if (!turn?.id) return false;
  const status = String(turn.status || "").toLowerCase();
  if (["completed", "failed", "interrupted", "cancelled", "canceled"].includes(status)) return false;
  return status === "inprogress" || status === "in_progress" || status === "active" || !turn.completedAt;
}

function findActiveTurnId(thread) {
  const turns = thread?.turns || [];
  for (let index = turns.length - 1; index >= 0; index -= 1) {
    if (isUnfinishedTurn(turns[index])) return turns[index].id;
  }
  return null;
}

async function resolveActiveTurn(threadId) {
  const cachedTurnId = client.getActiveTurn(threadId);
  if (cachedTurnId) return { turnId: cachedTurnId, source: "cache" };
  const result = await readThreadDetail(threadId);
  const thread = result.thread || result;
  const turnId = findActiveTurnId(thread);
  if (turnId) client.setActiveTurn(threadId, turnId);
  return { turnId, source: config.historySource === "cli-local" ? "cli-local" : "thread/read", thread };
}

async function handle(req, res, url) {
  if (req.method === "OPTIONS") {
    res.writeHead(204, {
      "access-control-allow-origin": "*",
      "access-control-allow-headers": "authorization, content-type",
      "access-control-allow-methods": "GET, POST, OPTIONS",
    });
    return res.end();
  }
  if (!authOk(req, url)) return json(res, 401, { error: "Unauthorized" });

  if (req.method === "GET" && url.pathname === "/api/health") {
    return json(res, 200, {
      ok: true,
      controller: "cloudex-codex-control",
      codexConnected: Boolean(client.socket && !client.socket.closed),
      controlSocket: config.controlSocketPath,
      mode: config.historySource === "cli-local" ? "cli-local-history" : "api-only",
      historySource: config.historySource,
      codexSessionsDir: config.codexSessionsDir,
      host: config.host,
      port: config.port,
      fileRoots: config.fileRoots,
    });
  }
  if (req.method === "GET" && url.pathname === "/api/models") {
    return json(res, 200, await listModels());
  }
  if (req.method === "GET" && url.pathname === "/api/projects") {
    const threads = await listAllThreads(false);
    return json(res, 200, { data: projectsFromThreads(threads), total: threads.length });
  }
  if (req.method === "GET" && url.pathname === "/api/threads") {
    const archived = url.searchParams.has("archived") ? url.searchParams.get("archived") === "true" : false;
    const data = await listAllThreads(archived);
    return json(res, 200, { data, nextCursor: null, total: data.length });
  }
  if (req.method === "GET" && url.pathname === "/api/events") {
    res.writeHead(200, {
      "content-type": "text/event-stream; charset=utf-8",
      "cache-control": "no-cache",
      connection: "keep-alive",
      "access-control-allow-origin": "*",
    });
    const cleanup = subscribeGlobal(res);
    writeSse(res, "ready", { mode: "api-only" });
    if (latestProjectSnapshot) writeSse(res, "threads/changed", { reason: "replay", ...latestProjectSnapshot });
    for (const { approval } of pendingApprovals.values()) writeSse(res, "approval/requested", approval);
    scheduleThreadSync("client-connected", 0);
    const keepAlive = setInterval(() => res.write(": keep-alive\n\n"), 15000);
    res.on("close", () => { clearInterval(keepAlive); cleanup(); });
    return;
  }
  if (req.method === "GET" && url.pathname === "/api/files") {
    return json(res, 200, { path: normalizePath(url.searchParams.get("path")), entries: await fileListing(url) });
  }
  if (req.method === "GET" && url.pathname === "/api/approvals") {
    return json(res, 200, { data: [...pendingApprovals.values()].map(({ approval }) => approval) });
  }
  const approvalMatch = url.pathname.match(/^\/api\/approvals\/([^/]+)\/respond$/);
  if (req.method === "POST" && approvalMatch) {
    const id = decodeURIComponent(approvalMatch[1]);
    const pendingApproval = pendingApprovals.get(id);
    if (!pendingApproval) {
      const error = new Error("Approval request is no longer pending");
      error.status = 409;
      throw error;
    }
    const data = await body(req);
    const decision = String(data.decision || "");
    const supported = new Set(["accept", "acceptForSession", "decline"]);
    if (!supported.has(decision)) {
      const error = new Error("decision must be accept, acceptForSession, or decline");
      error.status = 422;
      throw error;
    }
    if (pendingApproval.approval.method === "item/permissions/requestApproval") {
      const permissions = decision === "decline" ? {} : (pendingApproval.requestParams.permissions || {});
      const scope = decision === "acceptForSession" ? "session" : "turn";
      client.respondServerRequest(pendingApproval.rpcId, { permissions, scope });
    } else {
      client.respondServerRequest(pendingApproval.rpcId, { decision });
    }
    pendingApprovals.delete(id);
    broadcastGlobal("approval/resolved", { id, threadId: pendingApproval.approval.threadId, decision });
    scheduleThreadSync("approval-resolved", 100);
    return json(res, 200, { ok: true, id, decision });
  }
  const detailMatch = url.pathname.match(/^\/api\/threads\/([^/]+)$/);
  if (req.method === "GET" && detailMatch) {
    const threadId = decodeURIComponent(detailMatch[1]);
    const result = await readThreadDetail(threadId);
    return json(res, 200, result);
  }
  const streamMatch = url.pathname.match(/^\/api\/threads\/([^/]+)\/stream$/);
  if (req.method === "GET" && streamMatch) {
    const threadId = decodeURIComponent(streamMatch[1]);
    res.writeHead(200, {
      "content-type": "text/event-stream; charset=utf-8",
      "cache-control": "no-cache",
      connection: "keep-alive",
      "access-control-allow-origin": "*",
    });
    const cleanup = subscribe(threadId, res);
    writeSse(res, "ready", { threadId, mode: "api-only" });
    replayEvents(threadId, res);
    try {
      await client.subscribeThread(threadId);
      writeSse(res, "subscribed", { threadId });
    } catch (error) {
      writeSse(res, "error", { message: error.message || "Unable to subscribe to Codex task" });
    }
    const keepAlive = setInterval(() => res.write(": keep-alive\n\n"), 15000);
    res.on("close", () => { clearInterval(keepAlive); cleanup(); });
    return;
  }

  if (req.method === "POST" && url.pathname === "/api/threads") {
    const data = await body(req);
    const cwd = await normalizeThreadCwd(data.cwd || config.defaultCwd);
    const params = {
      cwd,
      model: data.model || null,
      sandbox: data.sandbox || "workspace-write",
      approvalPolicy: data.approvalPolicy || "on-request",
      personality: data.personality || null,
    };
    const result = await client.request("thread/start", params);
    const thread = result.thread || result;
    // thread/start automatically subscribes this app-server connection. Record
    // that fact immediately so a phone opening the new thread does not issue a
    // redundant thread/resume before its first rollout has been persisted.
    client.markThreadSubscribed(thread.id);
    let turn = null;
    if (data.prompt) {
      const turnResult = await client.request("turn/start", {
        threadId: thread.id,
        input: inputFrom({ message: data.prompt, files: data.files }),
        model: data.model || null,
        effort: data.effort || null,
      });
      turn = turnResult.turn || turnResult;
    }
    scheduleThreadSync("thread-created", 100);
    return json(res, 201, { thread, turn });
  }

  const threadMatch = url.pathname.match(/^\/api\/threads\/([^/]+)(?:\/(message|stop|archive))?$/);
  if (threadMatch) {
    const threadId = decodeURIComponent(threadMatch[1]);
    const action = threadMatch[2];
    if (req.method === "POST" && action === "message") {
      const data = await body(req);
      const resume = await client.subscribeThread(threadId);
      const turnResult = await client.request("turn/start", {
        threadId,
        input: inputFrom(data),
        model: data.model || null,
        effort: data.effort || null,
      });
      scheduleThreadSync("message-sent", 100);
      return json(res, 202, { thread: resume?.thread || resume || null, turn: turnResult.turn || turnResult });
    }
    if (req.method === "POST" && action === "stop") {
      const { turnId, source, thread } = await resolveActiveTurn(threadId);
      if (!turnId) {
        const status = thread?.status?.type ? ` (${thread.status.type})` : "";
        const error = new Error(`No active turn for this thread${status}`);
        error.status = 409;
        throw error;
      }
      const result = await client.request("turn/interrupt", { threadId, turnId });
      client.clearActiveTurn(threadId);
      scheduleThreadSync("turn-stopped", 100);
      return json(res, 200, { stopped: true, threadId, turnId, source, result });
    }
    if (req.method === "POST" && action === "archive") {
      if (config.historySource === "cli-local") {
        const result = await archiveCliThread(threadId);
        scheduleThreadSync("thread-archived", 100);
        return json(res, 200, result);
      }
      const result = await client.request("thread/archive", { threadId });
      scheduleThreadSync("thread-archived", 100);
      return json(res, 200, result);
    }
  }
  return json(res, 404, { error: "Not found" });
}

const server = http.createServer((req, res) => {
  const url = new URL(req.url, `http://${req.headers.host || "localhost"}`);
  handle(req, res, url).catch((error) => errorResponse(res, error));
});

async function main() {
  if (!config.isLoopback && !config.authToken) {
    throw new Error("HOST is not loopback; set AUTH_TOKEN before exposing the controller");
  }
  try {
    await client.start();
  } catch (error) {
    if (config.historySource !== "cli-local") throw error;
    console.warn(`Codex app-server control unavailable; local history will still be served: ${error.message}`);
  }
  startThreadSync();
  server.listen(config.port, config.host, () => {
    console.log(`Cloudex controller listening on http://${config.host}:${config.port}`);
    console.log(`History source: ${config.historySource}`);
    if (config.historySource === "cli-local") console.log(`Codex sessions: ${config.codexSessionsDir}`);
    console.log(`Allowed file roots: ${config.fileRoots.join(", ")}`);
    if (config.authToken) console.log("HTTP auth: Bearer token enabled");
  });
}

process.on("SIGINT", async () => { stopThreadSync(); await client.stop(); server.close(); process.exit(0); });
process.on("SIGTERM", async () => { stopThreadSync(); await client.stop(); server.close(); process.exit(0); });

main().catch((error) => {
  console.error(error.message);
  stopThreadSync();
  client.stop().catch(() => {});
  process.exitCode = 1;
});

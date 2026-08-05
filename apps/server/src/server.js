import http from "node:http";
import os from "node:os";
import fs from "node:fs/promises";
import path from "node:path";
import { execFile as execFileCallback } from "node:child_process";
import { promisify } from "node:util";
import { config } from "./config.js";
import { CodexClient, CodexError } from "./codex-client.js";
import { archiveCliThread, listCliThreads, readCliThreadById } from "./cli-sessions.js";
import {
  isWindowsPlatform,
  resumeThread as resumeWindowsThread,
  startNewThread as startWindowsThread,
  stopThread as stopWindowsThread,
} from "./windows-cli.js";
import { printConnectionQRCode } from "./connection-qr.js";
import { normalizeAllowedPath } from "./file-roots.js";

const client = new CodexClient();
const execFile = promisify(execFileCallback);
const subscribers = new Map();
const globalSubscribers = new Set();
const eventHistory = new Map();
const pendingApprovals = new Map();
const EVENT_HISTORY_LIMIT = 250;
const MODELS_CACHE_FILE = process.env.CLOUDEX_MODELS_CACHE
  || path.join(os.homedir(), ".codex", "models_cache.json");
const APPROVAL_HISTORY_FILE = path.join(config.stateDir, "approval-history.json");
let approvalHistory = null;
let approvalHistoryLoadPromise = null;
let approvalHistoryWrite = Promise.resolve();
let eventSequence = 0;
let latestThreadSignature = "";
let latestProjectSnapshot = null;
let syncInFlight = false;
let syncAgainReason = null;
let syncTimer = null;
let syncInterval = null;

async function loadApprovalHistory() {
  if (approvalHistory) return approvalHistory;
  if (!approvalHistoryLoadPromise) {
    approvalHistoryLoadPromise = (async () => {
      try {
        const value = JSON.parse(await fs.readFile(APPROVAL_HISTORY_FILE, "utf8"));
        approvalHistory = Array.isArray(value) ? value : [];
      } catch {
        approvalHistory = [];
      }
      return approvalHistory;
    })();
  }
  return approvalHistoryLoadPromise;
}

function approvalResolutionText(approval, decision) {
  const title = decision === "decline"
    ? "用户已禁止操作"
    : (decision === "acceptForSession" ? "用户已永久允许当前会话" : "用户已允许操作");
  const details = [];
  if (approval.reason) details.push(`说明：${approval.reason}`);
  const context = approval.networkApprovalContext;
  if (context?.host) {
    const scheme = context.protocol ? `${context.protocol}://` : "";
    const port = context.port ? `:${context.port}` : "";
    details.push(`网络：${scheme}${context.host}${port}`);
  }
  if (approval.permissionSummary) details.push(`权限：${approval.permissionSummary}`);
  if (approval.command) details.push(`命令：${approval.command}`);
  const targetPath = approval.grantRoot || approval.cwd;
  if (targetPath) details.push(`路径：${targetPath}`);
  return details.length > 0 ? `${title}\n${details.join("\n")}` : title;
}

async function recordApprovalResolution(approval, decision) {
  if (!approval?.threadId || !approval?.turnId || !decision) return;
  const history = await loadApprovalHistory();
  const id = `approval-${approval.id}-${decision}`;
  const record = {
    id,
    threadId: approval.threadId,
    turnId: approval.turnId,
    item: {
      type: "commandExecution",
      id,
      command: approvalResolutionText(approval, decision),
      activity: "approval",
      status: decision === "decline" ? "declined" : "completed",
      exitCode: null,
      duration: null,
      createdAt: Date.now() / 1000,
    },
  };
  const existingIndex = history.findIndex((value) => value.id === id);
  if (existingIndex >= 0) history[existingIndex] = record;
  else history.push(record);
  if (history.length > 2000) history.splice(0, history.length - 2000);
  approvalHistoryWrite = approvalHistoryWrite.then(async () => {
    await fs.mkdir(path.dirname(APPROVAL_HISTORY_FILE), { recursive: true });
    await fs.writeFile(APPROVAL_HISTORY_FILE, JSON.stringify(history), "utf8");
  });
  await approvalHistoryWrite;
}

async function mergeApprovalHistory(threadId, turns) {
  const history = await loadApprovalHistory();
  const byTurn = new Map();
  for (const record of history) {
    if (record.threadId !== threadId || !record.turnId || !record.item) continue;
    if (!byTurn.has(record.turnId)) byTurn.set(record.turnId, []);
    byTurn.get(record.turnId).push(record.item);
  }
  return turns.map((turn) => {
    const approvalItems = byTurn.get(turn.id) || [];
    if (approvalItems.length === 0) return turn;
    const items = [...(turn.items || [])];
    const existingIDs = new Set(items.map((item) => item.id).filter(Boolean));
    items.push(...approvalItems.filter((item) => !existingIDs.has(item.id)));
    const orderedItems = items.map((item, index) => ({ item, index })).sort((left, right) => {
      const leftTime = left.item.createdAt ?? Number.MAX_SAFE_INTEGER;
      const rightTime = right.item.createdAt ?? Number.MAX_SAFE_INTEGER;
      return leftTime === rightTime ? left.index - right.index : leftTime - rightTime;
    }).map(({ item }) => item);
    return { ...turn, items: orderedItems };
  });
}

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

function usesWindowsCliFallback() {
  return isWindowsPlatform() && (!client.socket || client.socket.closed);
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

async function readCliModelDefaults() {
  try {
    const source = await fs.readFile(config.codexConfigPath, "utf8");
    let section = "";
    let model = null;
    let effort = null;
    for (const rawLine of source.split("\n")) {
      const line = rawLine.trim();
      if (!line || line.startsWith("#")) continue;
      const sectionMatch = line.match(/^\[([^\]]+)\]$/);
      if (sectionMatch) {
        section = sectionMatch[1];
        continue;
      }
      if (section) continue;
      const valueMatch = line.match(/^([A-Za-z0-9_]+)\s*=\s*["']([^"']+)["']/);
      if (!valueMatch) continue;
      if (valueMatch[1] === "model") model = valueMatch[2].trim();
      if (valueMatch[1] === "model_reasoning_effort") effort = valueMatch[2].trim();
    }
    return { model, effort };
  } catch {
    return { model: null, effort: null };
  }
}

async function applyCliModelDefaults(response) {
  const configured = await readCliModelDefaults();
  if (!configured.model) return response;
  const data = [...(response?.data || [])];
  const index = data.findIndex((model) => (model.id || model.model) === configured.model);
  if (index >= 0) {
    data[index] = {
      ...data[index],
      isDefault: true,
      defaultReasoningEffort: configured.effort || data[index].defaultReasoningEffort || null,
    };
  } else {
    data.unshift(normalizeModel({
      id: configured.model,
      model: configured.model,
      displayName: configured.model,
      isDefault: true,
      defaultReasoningEffort: configured.effort,
      supportedReasoningEfforts: configured.effort ? [configured.effort] : [],
    }));
  }
  return {
    ...response,
    data: data.map((model) => ({
      ...model,
      isDefault: (model.id || model.model) === configured.model,
    })),
    configuredModel: configured.model,
    configuredReasoningEffort: configured.effort,
    source: "codex-cli",
  };
}

async function listModels() {
  if (!client.socket || client.socket.closed) {
    const cached = await readCachedModels();
    if (cached) return applyCliModelDefaults(cached);
  }
  try {
    return applyCliModelDefaults(normalizeModelsResponse(
      await client.request("model/list", { limit: 100 }),
    ));
  } catch (error) {
    const cached = await readCachedModels();
    if (cached) return applyCliModelDefaults(cached);
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

function fileContentType(filePath) {
  const extension = path.extname(filePath).toLowerCase();
  return ({
    ".txt": "text/plain; charset=utf-8",
    ".md": "text/markdown; charset=utf-8",
    ".json": "application/json; charset=utf-8",
    ".js": "text/javascript; charset=utf-8",
    ".ts": "text/plain; charset=utf-8",
    ".swift": "text/plain; charset=utf-8",
    ".html": "text/html; charset=utf-8",
    ".css": "text/css; charset=utf-8",
    ".xml": "application/xml; charset=utf-8",
    ".pdf": "application/pdf",
    ".png": "image/png",
    ".jpg": "image/jpeg",
    ".jpeg": "image/jpeg",
    ".gif": "image/gif",
    ".webp": "image/webp",
    ".svg": "image/svg+xml",
  })[extension] || "application/octet-stream";
}

async function sendFilePreview(res, candidate) {
  const filePath = await normalizeWorkspacePath(candidate);
  const metadata = await fs.stat(filePath);
  if (!metadata.isFile()) {
    const error = new Error("Path is not a file");
    error.status = 422;
    throw error;
  }
  if (metadata.size > 50 * 1024 * 1024) {
    const error = new Error("File is too large to preview (maximum 50 MB)");
    error.status = 413;
    throw error;
  }
  const data = await fs.readFile(filePath);
  res.writeHead(200, {
    "content-type": fileContentType(filePath),
    "content-length": data.length,
    "cache-control": "no-store",
    "access-control-allow-origin": "*",
  });
  res.end(data);
}

function errorResponse(res, error) {
  const status = error.status || (error instanceof CodexError ? 502 : 400);
  json(res, status, { error: error.message || "Request failed" });
}

function isImage(filePath) {
  return /\.(png|jpe?g|gif|webp|bmp|svg)$/i.test(filePath);
}

function normalizePath(candidate) {
  return normalizeAllowedPath(candidate, {
    defaultPath: config.defaultCwd,
    roots: config.fileRoots,
  });
}

function sandboxPolicyFor(sandbox) {
  switch (sandbox) {
  case "danger-full-access":
    return { type: "dangerFullAccess" };
  case "read-only":
    return { type: "readOnly" };
  default:
    return { type: "workspaceWrite" };
  }
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
  const pendingApproval = pendingApprovals.get(id);
  if (!pendingApproval) return;
  pendingApprovals.delete(id);
  const decision = message.params?.decision
    || message.params?.response?.decision
    || message.params?.result?.decision
    || null;
  void recordApprovalResolution(pendingApproval.approval, decision).catch((error) => {
    console.error("Failed to persist approval history:", error.message);
  });
  broadcastGlobal("approval/resolved", {
    id,
    threadId: message.params?.threadId || pendingApproval.approval.threadId || null,
    decision,
    approval: pendingApproval.approval,
  });
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

async function fileListing(candidate) {
  const dir = await normalizeWorkspacePath(candidate);
  const entries = await fs.readdir(dir, { withFileTypes: true });
  const data = await Promise.all(entries
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
  return { path: dir, entries: data };
}

async function runGit(cwd, args, { allowFailure = false } = {}) {
  try {
    return await execFile("git", args, {
      cwd,
      encoding: "utf8",
      maxBuffer: 32 * 1024 * 1024,
    });
  } catch (error) {
    if (allowFailure && (error.code === 1 || error.code === 128)) {
      return { stdout: error.stdout || "", stderr: error.stderr || "", code: error.code };
    }
    throw error;
  }
}

async function resolveReviewBase(gitRoot) {
  const candidates = [];
  try {
    const { stdout } = await runGit(gitRoot, ["symbolic-ref", "--quiet", "--short", "refs/remotes/origin/HEAD"]);
    if (stdout.trim()) candidates.push(stdout.trim());
  } catch {
    // Repositories without origin/HEAD are handled by the conventional names below.
  }
  candidates.push("origin/main", "origin/master");

  for (const candidate of [...new Set(candidates)]) {
    try {
      await runGit(gitRoot, ["rev-parse", "--verify", `${candidate}^{commit}`]);
      return candidate;
    } catch {
      // Try the next local origin ref.
    }
  }

  const error = new Error("未找到可用的 origin 分支");
  error.status = 409;
  throw error;
}

function parseGitNameStatus(value) {
  const tokens = value.split("\0").filter(Boolean);
  const records = [];
  for (let index = 0; index < tokens.length;) {
    const status = tokens[index++];
    if (!status) continue;
    if (status.startsWith("R") || status.startsWith("C")) {
      records.push({ status: status.startsWith("R") ? "renamed" : "copied", oldPath: tokens[index++], path: tokens[index++] });
    } else {
      const statusCode = status[0];
      records.push({
        status: statusCode === "A" ? "added" : statusCode === "D" ? "deleted" : "modified",
        oldPath: null,
        path: tokens[index++],
      });
    }
  }
  return records;
}

function parseUnifiedDiff(value) {
  const blocks = [];
  let current = null;
  let oldLine = 0;
  let newLine = 0;
  let inHunk = false;

  for (const rawLine of value.split("\n")) {
    if (rawLine.startsWith("diff --git ")) {
      if (current) blocks.push(current);
      current = { lines: [], binary: false };
      inHunk = false;
      continue;
    }
    if (!current) continue;
    if (rawLine.startsWith("Binary files ") || rawLine.startsWith("GIT binary patch")) {
      current.binary = true;
      continue;
    }
    const hunk = rawLine.match(/^@@ -(\d+)(?:,\d+)? \+(\d+)(?:,\d+)? @@/);
    if (hunk) {
      oldLine = Number(hunk[1]);
      newLine = Number(hunk[2]);
      inHunk = true;
      continue;
    }
    if (!inHunk || rawLine.startsWith("\\ No newline at end of file")) continue;
    const prefix = rawLine[0];
    if (prefix === "+") {
      current.lines.push({ kind: "addition", text: rawLine.slice(1), lineNumber: newLine++ });
    } else if (prefix === "-") {
      current.lines.push({ kind: "deletion", text: rawLine.slice(1), lineNumber: oldLine++ });
    } else if (prefix === " ") {
      current.lines.push({ kind: "context", text: rawLine.slice(1), lineNumber: newLine });
      oldLine += 1;
      newLine += 1;
    }
  }
  if (current) blocks.push(current);
  return blocks;
}

function countTextLines(value) {
  if (!value) return 0;
  const normalized = value.replace(/\r\n/g, "\n");
  return normalized.split("\n").length - (normalized.endsWith("\n") ? 1 : 0);
}

async function gitTextFileLineCount(gitRoot, base, relativePath) {
  const result = await runGit(gitRoot, ["show", base + ":" + relativePath], { allowFailure: true });
  if (result.code) return null;
  return countTextLines(result.stdout);
}

async function workspaceTextFileLineCount(gitRoot, relativePath) {
  try {
    const value = await fs.readFile(path.resolve(gitRoot, relativePath), "utf8");
    return countTextLines(value);
  } catch {
    return null;
  }
}

async function projectReview(candidate) {
  const workspacePath = await normalizeWorkspacePath(candidate);
  const metadata = await fs.stat(workspacePath);
  if (!metadata.isDirectory()) {
    const error = new Error("审阅路径必须是目录");
    error.status = 422;
    throw error;
  }

  const { stdout: rootOutput } = await runGit(workspacePath, ["rev-parse", "--show-toplevel"]);
  const gitRoot = path.resolve(rootOutput.trim());
  const base = await resolveReviewBase(gitRoot);
  const scope = path.relative(gitRoot, workspacePath);
  const scopeArgs = scope ? [scope] : [];
  const diffArgs = ["diff", "--no-ext-diff", "--no-color", "--find-renames", "--unified=3", base, "--", ...scopeArgs];
  const { stdout: nameStatusOutput } = await runGit(gitRoot, ["diff", "--name-status", "-z", "--find-renames", base, "--", ...scopeArgs]);
  const { stdout: diffOutput } = await runGit(gitRoot, diffArgs);
  const records = parseGitNameStatus(nameStatusOutput);
  const blocks = parseUnifiedDiff(diffOutput);

  const { stdout: untrackedOutput } = await runGit(gitRoot, ["ls-files", "--others", "--exclude-standard", "-z", "--", ...scopeArgs]);
  const untrackedPaths = untrackedOutput.split("\0").filter(Boolean);
  for (const relativePath of untrackedPaths) {
    const { stdout: untrackedDiff } = await runGit(gitRoot, ["diff", "--no-index", "--no-color", "--unified=3", "--", "/dev/null", relativePath], { allowFailure: true });
    const parsed = parseUnifiedDiff(untrackedDiff);
    records.push({ status: "added", oldPath: null, path: relativePath, untracked: true });
    blocks.push(parsed[0] || { lines: [], binary: false });
  }

  const files = await Promise.all(records.map(async (record, index) => {
    const block = blocks[index] || { lines: [], binary: false };
    const displayPath = path.relative(workspacePath, path.resolve(gitRoot, record.path)) || path.basename(record.path);
    const additions = block.lines.filter((line) => line.kind === "addition").length;
    const deletions = block.lines.filter((line) => line.kind === "deletion").length;
    const oldLineCount = block.binary || record.status === "added"
      ? (record.status === "added" && !record.untracked
        ? await gitTextFileLineCount(gitRoot, base, record.oldPath || record.path)
        : 0)
      : await gitTextFileLineCount(gitRoot, base, record.oldPath || record.path);
    const newLineCount = block.binary || record.status === "deleted"
      ? null
      : await workspaceTextFileLineCount(gitRoot, record.path);
    return {
      path: displayPath,
      status: record.status,
      additions,
      deletions,
      binary: block.binary,
      oldLineCount,
      newLineCount,
      lines: block.lines,
    };
  }));

  return { path: workspacePath, base, files, generatedAt: Date.now() };
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

async function readThreadDetail(threadId, { limit = Number.MAX_SAFE_INTEGER, before = null, around = null } = {}) {
  const fullDetail = config.historySource === "cli-local"
    ? await readCliThreadById(threadId)
    : await client.request("thread/read", { threadId, includeTurns: true }).then((result) => {
        const thread = result.thread || result;
        return { thread, turns: thread.turns || [] };
      });
  const turns = await mergeApprovalHistory(threadId, fullDetail.turns || []);
  const aroundIndex = around ? turns.findIndex((turn) => turn.id === around) : -1;
  const beforeIndex = before ? turns.findIndex((turn) => turn.id === before) : turns.length;
  let end = beforeIndex >= 0 ? beforeIndex : turns.length;
  let start = Math.max(0, end - limit);
  if (aroundIndex >= 0) {
    start = Math.max(0, aroundIndex - Math.floor((limit - 1) / 2));
    end = Math.min(turns.length, start + limit);
    start = Math.max(0, end - limit);
  }
  const page = turns.slice(start, end);
  return {
    thread: fullDetail.thread,
    turns: page,
    hasMoreBefore: start > 0,
    nextBefore: start > 0 ? page[0]?.id || null : null,
  };
}

function itemText(item) {
  const contentText = (item.content || []).map((part) => part.text || part.value || "").join("");
  return String(item.type === "userMessage" ? contentText : (item.text || contentText)).trim();
}

function messageIndexFromDetail(detail) {
  const data = searchableConversationMessages(detail.turns).map((item) => ({
    ...item,
    text: item.text.slice(0, 240),
  }));
  return { data };
}

function searchableConversationMessages(turns = []) {
  const data = [];
  for (const turn of turns) {
    const items = turn.items || [];
    const finalAgentIndex = items.findLastIndex((item) => item.type === "agentMessage" && item.phase === "final_answer") >= 0
      ? items.findLastIndex((item) => item.type === "agentMessage" && item.phase === "final_answer")
      : items.findLastIndex((item) => item.type === "agentMessage");
    items.forEach((item, index) => {
      if (item.type !== "userMessage" && index !== finalAgentIndex) return;
      const text = itemText(item);
      if (!text) return;
      data.push({
        id: item.id || `${turn.id}-${item.type}-${index}`,
        turnId: turn.id,
        role: item.type === "userMessage" ? "user" : "assistant",
        text: text.replace(/\s+/g, " "),
        createdAt: item.createdAt || turn.startedAt || null,
      });
    });
  }
  return data;
}

function searchSnippet(text, query) {
  const normalized = String(text || "").replace(/\s+/g, " ").trim();
  const index = normalized.toLocaleLowerCase().indexOf(query.toLocaleLowerCase());
  if (index < 0) return null;
  const start = Math.max(0, index - 70);
  const end = Math.min(normalized.length, index + query.length + 110);
  return `${start > 0 ? "…" : ""}${normalized.slice(start, end)}${end < normalized.length ? "…" : ""}`;
}

async function searchConversationMessages(query) {
  const trimmed = String(query || "").trim();
  if (!trimmed) return [];
  const threads = await listAllThreads(false);
  const settled = await Promise.allSettled(threads.map(async (thread) => {
    const turns = Array.isArray(thread.turns)
      ? thread.turns
      : (await readThreadDetail(thread.id)).turns;
    return searchableConversationMessages(turns).flatMap((item) => {
      const snippet = searchSnippet(item.text, trimmed);
      if (!snippet) return [];
      return [{
        id: `${thread.id}:${item.id}`,
        threadId: thread.id,
        messageId: item.id,
        turnId: item.turnId,
        role: item.role,
        text: item.text.slice(0, 240),
        snippet,
        createdAt: item.createdAt,
      }];
    });
  }));
  return settled
    .filter((result) => result.status === "fulfilled")
    .flatMap((result) => result.value)
    .slice(0, 500);
}

function compactTurn(turn) {
  const items = turn.items || [];
  // An active turn has no stable "final" item yet. Compacting it to the last
  // assistant message makes a relaunched client lose all earlier commentary
  // and tool executions from the same task. Keep the active turn complete;
  // completed turns still use the lightweight representation below.
  if (turn.status === "inProgress") {
    return {
      ...turn,
      items,
      itemsView: "full",
      processItemCount: 0,
      detailsLoaded: true,
    };
  }
  const finalAgentIndex = items.findLastIndex((item) => item.type === "agentMessage" && item.phase === "final_answer") >= 0
    ? items.findLastIndex((item) => item.type === "agentMessage" && item.phase === "final_answer")
    : items.findLastIndex((item) => item.type === "agentMessage");
  const visibleItems = items.filter((item, index) => item.type === "userMessage" || index === finalAgentIndex);
  const processItemCount = Math.max(0, items.length - visibleItems.length);
  return {
    ...turn,
    items: visibleItems,
    processItemCount,
    detailsLoaded: processItemCount === 0,
  };
}

function compactThreadDetail(detail) {
  return {
    thread: detail.thread,
    turns: (detail.turns || []).map(compactTurn),
    hasMoreBefore: false,
    nextBefore: null,
  };
}

const NO_PROJECT_CWD = "未指定项目目录";

function projectCwdForThread(thread) {
  const cwd = String(thread.cwd || "").trim();
  if (!cwd || cwd === NO_PROJECT_CWD) return NO_PROJECT_CWD;

  const resolved = path.resolve(cwd);
  const home = path.resolve(os.homedir());
  const codexScratchRoot = path.join(home, "Documents", "Codex");
  const codexStateRoot = path.join(home, ".codex");
  const isInside = (root) => {
    const relative = path.relative(root, resolved);
    return relative === "" || (!relative.startsWith("..") && !path.isAbsolute(relative));
  };

  // Codex creates dated scratch directories when a conversation is started
  // without choosing a project. Their final path component looks like a
  // project name (for example bh-w or token-api-api), but it is not one.
  if (resolved === home || isInside(codexScratchRoot) || isInside(codexStateRoot)) {
    return NO_PROJECT_CWD;
  }
  return cwd;
}

function projectsFromThreads(threads) {
  const projects = new Map();
  for (const thread of threads) {
    const cwd = projectCwdForThread(thread);
    if (!projects.has(cwd)) {
      projects.set(cwd, {
        id: cwd,
        name: cwd === NO_PROJECT_CWD ? "无项目" : path.basename(cwd) || cwd,
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

function projectRootsFromThreads(threads) {
  return projectsFromThreads(threads)
    .map((project) => project.cwd)
    .filter((cwd) => cwd && cwd !== NO_PROJECT_CWD)
    .map((cwd) => path.resolve(cwd));
}

async function normalizeWorkspacePath(candidate) {
  try {
    return normalizePath(candidate);
  } catch (error) {
    if (error.status !== 403) throw error;
  }

  const cachedRoots = (latestProjectSnapshot?.projects || [])
    .map((project) => project.cwd)
    .filter((cwd) => cwd && cwd !== NO_PROJECT_CWD)
    .map((cwd) => path.resolve(cwd));
  try {
    return normalizeAllowedPath(candidate, {
      defaultPath: config.defaultCwd,
      roots: cachedRoots,
    });
  } catch (error) {
    if (error.status !== 403) throw error;
  }

  return normalizeAllowedPath(candidate, {
    defaultPath: config.defaultCwd,
    roots: projectRootsFromThreads(await listAllThreads(false)),
  });
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
    if (!usesWindowsCliFallback()) {
      const runningThreads = threads.filter((thread) => thread.status?.type === "active");
      await Promise.allSettled(runningThreads.map((thread) => client.subscribeThread(thread.id)));
    }
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

async function inputFrom(bodyData) {
  const message = String(bodyData.message || "").trim();
  if (!message) {
    const error = new Error("message is required");
    error.status = 422;
    throw error;
  }
  const input = [{ type: "text", text: message }];
  for (const file of bodyData.files || []) {
    const filePath = await normalizeWorkspacePath(file.path || file);
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
  if (req.method === "GET" && url.pathname === "/api/search/messages") {
    const query = url.searchParams.get("q") || "";
    return json(res, 200, { data: await searchConversationMessages(query) });
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
    return json(res, 200, await fileListing(url.searchParams.get("path")));
  }
  if (req.method === "GET" && url.pathname === "/api/review") {
    return json(res, 200, await projectReview(url.searchParams.get("path")));
  }
  if (req.method === "GET" && url.pathname === "/api/file") {
    return sendFilePreview(res, url.searchParams.get("path"));
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
    await recordApprovalResolution(pendingApproval.approval, decision);
    broadcastGlobal("approval/resolved", {
      id,
      threadId: pendingApproval.approval.threadId,
      decision,
      approval: pendingApproval.approval,
    });
    scheduleThreadSync("approval-resolved", 100);
    return json(res, 200, { ok: true, id, decision });
  }
  const detailMatch = url.pathname.match(/^\/api\/threads\/([^/]+)$/);
  if (req.method === "GET" && detailMatch) {
    const threadId = decodeURIComponent(detailMatch[1]);
    const rawLimit = url.searchParams.get("limit");
    const requestedLimit = rawLimit === null ? Number.MAX_SAFE_INTEGER : Number.parseInt(rawLimit, 10);
    const limit = rawLimit === null
      ? Number.MAX_SAFE_INTEGER
      : (Number.isFinite(requestedLimit) ? Math.min(20, Math.max(1, requestedLimit)) : 3);
    const before = url.searchParams.get("before") || null;
    const around = url.searchParams.get("around") || null;
    const result = await readThreadDetail(threadId, { limit, before, around });
    return json(res, 200, url.searchParams.get("view") === "compact" ? compactThreadDetail(result) : result);
  }
  const turnDetailMatch = url.pathname.match(/^\/api\/threads\/([^/]+)\/turns\/([^/]+)$/);
  if (req.method === "GET" && turnDetailMatch) {
    const threadId = decodeURIComponent(turnDetailMatch[1]);
    const turnId = decodeURIComponent(turnDetailMatch[2]);
    const detail = await readThreadDetail(threadId);
    const turn = detail.turns.find((candidate) => candidate.id === turnId);
    if (!turn) {
      const error = new Error("Turn not found");
      error.status = 404;
      throw error;
    }
    return json(res, 200, { turn: { ...turn, detailsLoaded: true, processItemCount: null } });
  }
  const messageIndexMatch = url.pathname.match(/^\/api\/threads\/([^/]+)\/message-index$/);
  if (req.method === "GET" && messageIndexMatch) {
    const threadId = decodeURIComponent(messageIndexMatch[1]);
    const detail = await readThreadDetail(threadId);
    return json(res, 200, messageIndexFromDetail(detail));
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
    // Let clients distinguish replayed history from newly arriving events.
    writeSse(res, "replay-complete", { threadId });
    if (usesWindowsCliFallback()) {
      // Windows runs the Codex CLI as a child process. Its JSONL events are
      // bridged into publish() below, so the SSE channel stays open and the
      // app receives live notifications instead of polling only.
      writeSse(res, "subscribed", { threadId });
    } else {
      try {
        await client.subscribeThread(threadId);
        writeSse(res, "subscribed", { threadId });
      } catch (error) {
        writeSse(res, "error", { message: error.message || "Unable to subscribe to Codex task" });
      }
    }
    const keepAlive = setInterval(() => res.write(": keep-alive\n\n"), 15000);
    res.on("close", () => { clearInterval(keepAlive); cleanup(); });
    return;
  }

  if (req.method === "POST" && url.pathname === "/api/threads") {
    const data = await body(req);
    const cwd = await normalizeThreadCwd(data.cwd || config.defaultCwd);
    let thread = null;
    let turn = null;
    if (usesWindowsCliFallback()) {
      const threadId = await startWindowsThread({
        cwd,
        prompt: data.prompt,
        files: data.files,
        model: data.model || null,
        effort: data.effort || null,
        sandbox: data.sandbox || "workspace-write",
        approvalPolicy: data.approvalPolicy || "on-request",
        approvalsReviewer: data.approvalsReviewer || "user",
        onAppMessage: (message) => publish(message),
      });
      thread = (await readCliThreadById(threadId)).thread;
    } else {
      const params = {
        cwd,
        model: data.model || null,
        sandbox: data.sandbox || "workspace-write",
        approvalPolicy: data.approvalPolicy || "on-request",
        approvalsReviewer: data.approvalsReviewer || "user",
        personality: data.personality || null,
      };
      const result = await client.request("thread/start", params);
      thread = result.thread || result;
      // thread/start automatically subscribes this app-server connection. Record
      // that fact immediately so a phone opening the new thread does not issue a
      // redundant thread/resume before its first rollout has been persisted.
      client.markThreadSubscribed(thread.id);
      if (data.prompt) {
        const turnResult = await client.request("turn/start", {
          threadId: thread.id,
          input: await inputFrom({ message: data.prompt, files: data.files }),
          model: data.model || null,
          effort: data.effort || null,
          approvalPolicy: data.approvalPolicy || "on-request",
          approvalsReviewer: data.approvalsReviewer || "user",
          sandboxPolicy: sandboxPolicyFor(data.sandbox || "workspace-write"),
        });
        turn = turnResult.turn || turnResult;
      }
    }
    scheduleThreadSync("thread-created", 100);
    return json(res, 201, { thread, turn });
  }

  const threadMatch = url.pathname.match(/^\/api\/threads\/([^/]+)(?:\/(message|stop|archive|fork))?$/);
  if (threadMatch) {
    const threadId = decodeURIComponent(threadMatch[1]);
    const action = threadMatch[2];
    if (req.method === "POST" && action === "message") {
      const data = await body(req);
      let thread = null;
      let turn = null;
      if (usesWindowsCliFallback()) {
        const input = await inputFrom(data);
        const prompt = input.map((part) => part.type === "text" ? part.text : "").join("\n").trim();
        const images = input.filter((part) => part.type === "localImage");
        await resumeWindowsThread({
          threadId,
          prompt,
          files: images,
          model: data.model || null,
          effort: data.effort || null,
          sandbox: data.sandbox || "workspace-write",
          approvalPolicy: data.approvalPolicy || "on-request",
          approvalsReviewer: data.approvalsReviewer || "user",
          onAppMessage: (message) => publish(message),
        });
      } else {
        const resume = await client.subscribeThread(threadId);
        const turnResult = await client.request("turn/start", {
          threadId,
          input: await inputFrom(data),
          model: data.model || null,
          effort: data.effort || null,
          approvalPolicy: data.approvalPolicy || "on-request",
          approvalsReviewer: data.approvalsReviewer || "user",
          sandboxPolicy: sandboxPolicyFor(data.sandbox || "workspace-write"),
        });
        thread = resume?.thread || resume || null;
        turn = turnResult.turn || turnResult;
      }
      scheduleThreadSync("message-sent", 100);
      return json(res, 202, { thread, turn });
    }
    if (req.method === "POST" && action === "fork") {
      if (usesWindowsCliFallback()) {
        const error = new Error("Fork is not supported on Windows CLI mode");
        error.status = 501;
        throw error;
      }
      const data = await body(req);
      const turnId = String(data.turnId || "").trim();
      if (!turnId) {
        const error = new Error("turnId is required");
        error.status = 422;
        throw error;
      }
      const forkParams = { threadId };
      if (data.position === "before") forkParams.beforeTurnId = turnId;
      else forkParams.lastTurnId = turnId;
      const forkResult = await client.request("thread/fork", forkParams);
      const forkedThread = forkResult.thread || forkResult;
      client.markThreadSubscribed(forkedThread.id);

      let turn = null;
      const editedMessage = String(data.message || "").trim();
      if (editedMessage) {
        const turnResult = await client.request("turn/start", {
          threadId: forkedThread.id,
          input: await inputFrom({ message: editedMessage, files: data.files }),
          model: data.model || null,
          effort: data.effort || null,
          approvalPolicy: data.approvalPolicy || "on-request",
          approvalsReviewer: data.approvalsReviewer || "user",
          sandboxPolicy: sandboxPolicyFor(data.sandbox || "workspace-write"),
        });
        turn = turnResult.turn || turnResult;
      }
      scheduleThreadSync("thread-forked", 100);
      return json(res, 201, { thread: forkedThread, turn });
    }
    if (req.method === "POST" && action === "stop") {
      if (usesWindowsCliFallback()) {
        const stopped = stopWindowsThread(threadId);
        if (!stopped) {
          const error = new Error("No active turn for this thread");
          error.status = 409;
          throw error;
        }
        scheduleThreadSync("turn-stopped", 100);
        return json(res, 200, { stopped: true, threadId, turnId: null, source: "windows-cli" });
      }
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
  // Show pairing information immediately. Starting the Codex control client
  // can take a moment, but the phone can already capture the connection data.
  printConnectionQRCode({ host: config.host, port: config.port, authToken: config.authToken });
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

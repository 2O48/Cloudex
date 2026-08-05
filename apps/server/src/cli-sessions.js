import os from "node:os";
import fs from "node:fs/promises";
import path from "node:path";
import { config } from "./config.js";

const SESSION_FILE_RE = /rollout-.*-([0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12})\.jsonl$/i;
const ARCHIVE_FILE = path.join(config.stateDir, "archived-cli-threads.json");
const SESSION_INDEX_FILE = path.join(os.homedir(), ".codex", "session_index.jsonl");
let sessionIndexSignature = "";
let sessionIndexNames = new Map();

async function readSessionIndexNames() {
  try {
    const stat = await fs.stat(SESSION_INDEX_FILE);
    const signature = `${stat.mtimeMs}:${stat.size}`;
    if (signature === sessionIndexSignature) return sessionIndexNames;

    const names = new Map();
    const raw = await fs.readFile(SESSION_INDEX_FILE, "utf8");
    for (const line of raw.split("\n")) {
      const record = safeJson(line);
      const id = typeof record?.id === "string" ? record.id.trim() : "";
      const name = [record?.thread_name, record?.name, record?.title]
        .find((value) => typeof value === "string" && value.trim());
      if (id && name) names.set(id, name.trim());
    }
    sessionIndexSignature = signature;
    sessionIndexNames = names;
  } catch {
    sessionIndexSignature = "";
    sessionIndexNames = new Map();
  }
  return sessionIndexNames;
}

function timestampSeconds(value) {
  if (typeof value === "number") return value > 1_000_000_000_000 ? Math.floor(value / 1000) : value;
  const parsed = Date.parse(value || "");
  return Number.isFinite(parsed) ? Math.floor(parsed / 1000) : 0;
}

function timestampPrecise(value) {
  if (typeof value === "number") return value > 1_000_000_000_000 ? value / 1000 : value;
  const parsed = Date.parse(value || "");
  return Number.isFinite(parsed) ? parsed / 1000 : 0;
}

function safeJson(line) {
  try { return JSON.parse(line); } catch { return null; }
}

function redactCommand(command) {
  return String(command || "")
    .replace(/(Authorization:\s*Bearer\s+)[^'"\s]+/gi, "$1[REDACTED]")
    .replace(/\b(OPENAI_API_KEY|AUTH_TOKEN|CODEX_API_KEY)=(["'])?(?!\$\()[^\s"']+\2/gi, "$1=[REDACTED]");
}

function commandResult(output) {
  const value = String(output || "");
  const exitCodeMatch = value.match(/Process exited with code\s+(-?\d+)|Exit code:\s*(-?\d+)/i);
  const durationMatch = value.match(/Wall time:\s*([^\n\r]+)/i);
  const exitCode = exitCodeMatch ? Number(exitCodeMatch[1] ?? exitCodeMatch[2]) : null;
  let status = "completed";
  if (exitCode !== null) status = exitCode === 0 ? "completed" : "failed";
  else if (/Process running with session ID|Script running with cell ID/i.test(value)) status = "inProgress";
  return { status, exitCode, duration: durationMatch?.[1]?.trim() || null };
}

function jsStringProperty(source, property) {
  const escapedProperty = property.replace(/[.*+?^${}()|[\]\\]/g, "\\$&");
  const match = String(source || "").match(new RegExp(`(?:^|[,{\\s])['\"]?${escapedProperty}['\"]?\\s*:\\s*("(?:\\\\.|[^"\\\\])*"|'(?:\\\\.|[^'\\\\])*')`));
  if (!match) return null;
  const literal = match[1];
  if (literal.startsWith('"')) {
    try { return JSON.parse(literal); } catch { return null; }
  }
  return literal.slice(1, -1)
    .replace(/\\'/g, "'")
    .replace(/\\n/g, "\n")
    .replace(/\\r/g, "\r")
    .replace(/\\t/g, "\t")
    .replace(/\\\\/g, "\\");
}

function jsNumberProperty(source, property) {
  const escapedProperty = property.replace(/[.*+?^${}()|[\]\\]/g, "\\$&");
  const match = String(source || "").match(new RegExp(`(?:^|[,{\\s])['\"]?${escapedProperty}['\"]?\\s*:\\s*(\\d+)`));
  return match ? Number(match[1]) : null;
}

function jsAssignedString(source, variable) {
  const match = String(source || "").match(new RegExp(`\\b(?:const|let|var)\\s+${variable}\\s*=\\s*("(?:\\\\.|[^"\\\\])*")`));
  if (!match) return null;
  try { return JSON.parse(match[1]); } catch { return null; }
}

export function commandActivity(command) {
  const value = String(command || "").trim();
  const mutating = /(^|[;&|]\s*)(npm|npx|node|xcodebuild|make|kill|mv|cp|rm|mkdir|touch|chmod|git\s+(add|commit|push|pull|checkout|switch|restore|reset)|curl\b[^\n]*(--request|-X)\s*(POST|PUT|PATCH|DELETE))\b/i;
  if (mutating.test(value)) return "ran";
  const explored = /(^|[;&|]\s*|\b)(rg|grep|find|fd|ls|pwd|head|tail|cat|wc|stat|which|ps\s+aux|sed\s+-n|git\s+(status|diff|log|show)|command\s+-v)\b/i;
  return explored.test(value) ? "explored" : "ran";
}

function editedFiles(patch) {
  const sections = editedPatchSections(patch);
  return editedFilesFromSections(sections);
}

function editedFilesFromSections(sections) {
  if (sections.length === 0) return "files";
  return sections.map((section) => {
    const title = `${section.name} +${section.additions} -${section.deletions}`;
    if (section.snippets.length === 0) return title;
    return `${title}\n${section.snippets.join("\n")}`;
  }).join("\n");
}

function editedPatchSections(patch) {
  const sections = [];
  let current = null;
  for (const line of String(patch || "").split(/\r?\n/)) {
    const header = line.match(/^\*\*\* (?:Update|Add|Delete) File:\s*(.+)$/);
    if (header) {
    current = { name: path.basename(header[1].trim()), lines: [] };
    sections.push(current);
    continue;
  }
    if (!current || line.startsWith("*** ")) continue;
    if (line.startsWith("*** Move to:")) continue;
    current.lines.push(line);
  }
  return sections.map((section) => ({
    name: section.name,
    additions: section.lines.filter((line) => line.trimStart().startsWith("+")).length,
    deletions: section.lines.filter((line) => line.trimStart().startsWith("-")).length,
    snippets: patchSnippets(section.lines),
    lines: patchDiffLines(section.lines),
  })).filter((section) => section.name);
}

function patchSnippets(lines) {
  const changedIndexes = lines
    .map((line, index) => (/^[+-]/.test(line) ? index : -1))
    .filter((index) => index >= 0);
  const snippets = [];
  let cursor = 0;
  while (cursor < changedIndexes.length && snippets.length < 10) {
    const start = changedIndexes[cursor];
    let end = start;
    cursor += 1;
    while (cursor < changedIndexes.length && changedIndexes[cursor] <= end + 1) {
      end = changedIndexes[cursor];
      cursor += 1;
    }
    const from = Math.max(0, start - 1);
    const to = Math.min(lines.length - 1, end + 1);
    for (let index = from; index <= to; index += 1) {
      const rendered = renderPatchLine(lines[index]);
      const text = stringifyPatchLine(rendered);
      if (text && !snippets.includes(text)) snippets.push(text);
    }
  }
  return snippets;
}

function patchDiffLines(lines) {
  const result = [];
  let oldLineNumber = 1;
  let newLineNumber = 1;
  for (const rawLine of lines) {
    if (rawLine.startsWith("@@")) {
      result.push({ kind: "header", text: rawLine.trim(), lineNumber: null });
      const range = rawLine.match(/^@@\s+-(\d+)(?:,\d+)?\s+\+(\d+)(?:,\d+)?\s+@@/);
      if (range) {
        oldLineNumber = Number(range[1]);
        newLineNumber = Number(range[2]);
      }
      continue;
    }
    const parsed = renderPatchLine(rawLine);
    if (!parsed) continue;
    const kind = parsed.kind;
    if (kind === "context") {
      result.push({ kind, text: parsed.text, lineNumber: newLineNumber });
      oldLineNumber += 1;
      newLineNumber += 1;
    } else if (kind === "addition") {
      result.push({ kind, text: parsed.text, lineNumber: newLineNumber });
      newLineNumber += 1;
    } else if (kind === "deletion") {
      result.push({ kind, text: parsed.text, lineNumber: oldLineNumber });
      oldLineNumber += 1;
    }
  }
  return result;
}

function stringifyPatchLine(line) {
  if (!line) return "";
  if (line.kind === "addition") return `  + ${line.text}`;
  if (line.kind === "deletion") return `  - ${line.text}`;
  if (line.kind === "context") return `    ${line.text}`;
  return line.text || "";
}

function renderPatchLine(line) {
  if (!line) return "";
  const prefix = line[0];
  const value = line.slice(1).trimEnd();
  if (prefix === "+") return { kind: "addition", text: value };
  if (prefix === "-") return { kind: "deletion", text: value };
  if (prefix === " ") return { kind: "context", text: value.trimEnd() };
  return { kind: "context", text: line.trimEnd() };
}

function nestedExecInvocation(input) {
  if (input && typeof input === "object") {
    const command = input.cmd || input.command || input.arguments?.cmd || input.arguments?.command;
    if (typeof command === "string" && command.trim()) return { type: "command", command };
    const patch = input.patch || input.arguments?.patch;
    if (typeof patch === "string") return { type: "edit", patch };
    const sessionId = input.session_id ?? input.sessionId ?? input.arguments?.session_id ?? input.arguments?.sessionId;
    if (Number.isFinite(Number(sessionId))) return { type: "resume", sessionId: Number(sessionId) };
  }
  const source = String(input || "");
  try {
    const parsed = JSON.parse(source);
    if (parsed && parsed !== input) return nestedExecInvocation(parsed);
  } catch { /* Legacy tool inputs are source snippets, not JSON. */ }
  if (/tools\.apply_patch\s*\(/.test(source)) {
    return { type: "edit", patch: jsAssignedString(source, "patch") || "" };
  }
  if (/tools\.exec_command\s*\(/.test(source)) {
    return { type: "command", command: jsStringProperty(source, "cmd") };
  }
  if (/tools\.write_stdin\s*\(/.test(source)) {
    return { type: "resume", sessionId: jsNumberProperty(source, "session_id") };
  }
  return null;
}

function outputParts(output) {
  if (typeof output === "string") return [output];
  if (!Array.isArray(output)) return [];
  return output.map((item) => item?.text || item?.value || item?.input_text || item?.output_text || "").filter(Boolean);
}

function embeddedResultObjects(output) {
  const objects = [];
  for (const part of outputParts(output)) {
    const candidates = [part.trim(), ...part.split("\n").map((line) => line.trim())];
    for (const candidate of candidates) {
      if (!candidate.startsWith("{") || !candidate.endsWith("}")) continue;
      try {
        const value = JSON.parse(candidate);
        if (value && typeof value === "object") objects.push(value);
      } catch { /* The output line is not a standalone JSON result. */ }
    }
  }
  return objects;
}

function customToolResult(output) {
  const text = outputParts(output).join("\n");
  const result = embeddedResultObjects(output).find((value) =>
    Number.isFinite(value.exit_code) || Number.isFinite(value.session_id) || Number.isFinite(value.wall_time_seconds));
  if (result) {
    const exitCode = Number.isFinite(result.exit_code) ? result.exit_code : null;
    return {
      status: exitCode === null ? "inProgress" : (exitCode === 0 ? "completed" : "failed"),
      exitCode,
      duration: Number.isFinite(result.wall_time_seconds) ? `${result.wall_time_seconds} seconds` : null,
      sessionId: Number.isFinite(result.session_id) ? result.session_id : null,
    };
  }
  return { ...commandResult(text), sessionId: null };
}

function textFromContent(content = []) {
  if (typeof content === "string") return content;
  if (!Array.isArray(content)) return "";
  return content.map((item) => item.text || item.value || item.input_text || item.output_text || "").join("").trim();
}

function outputTextFromResponse(payload) {
  if (!payload) return "";
  if (typeof payload.message === "string") return payload.message;
  if (typeof payload.text === "string") return payload.text;
  return textFromContent(payload.content);
}

function threadNameFromPayload(payload) {
  const candidates = [
    payload?.thread?.name,
    payload?.thread?.title,
    payload?.name,
    payload?.title,
    payload?.thread_name,
    payload?.threadName,
  ];
  return candidates
    .map((value) => typeof value === "string" ? value.trim() : "")
    .find((value) => value && !["exec", "apply_patch"].includes(value.toLowerCase())) || null;
}

function errorFromPayload(error) {
  if (!error) return null;
  if (typeof error === "string") return { message: error };
  return {
    message: error.message || JSON.stringify(error),
    codexErrorInfo: error.codexErrorInfo || error.codex_error_info || error.code || error.type || null,
    additionalDetails: error.additionalDetails || error.additional_details || null,
  };
}

function itemPlainText(item) {
  if (!item) return "";
  if (item.type === "userMessage") return textFromContent(item.content);
  if (item.type === "commandExecution") return item.command || "";
  return item.text || "";
}

function addUniqueItem(turn, item) {
  if (!item?.text && item.type !== "userMessage" && item.type !== "commandExecution") return;
  if (turn.items.some((existing) => existing.id === item.id)) return;
  const text = itemPlainText(item).trim();
  if (text && turn.items.some((existing) => existing.type === item.type && itemPlainText(existing).trim() === text)) return;
  turn.items.push(item);
}

function removeCompactionSummary(state, compactionMessage) {
  const wrapper = String(compactionMessage || "");
  for (let turnIndex = state.turns.length - 1; turnIndex >= 0; turnIndex -= 1) {
    const turn = state.turns[turnIndex];
    for (let itemIndex = turn.items.length - 1; itemIndex >= 0; itemIndex -= 1) {
      const item = turn.items[itemIndex];
      if (item.type !== "agentMessage") continue;
      const text = itemPlainText(item).trim();
      if (!text) continue;
      const normalized = text.replace(/^\s+/, "");
      const looksLikeHandoff = /^(?:#+\s*|\*\*)?handoff summary\b/i.test(normalized);
      if (!looksLikeHandoff && !wrapper.includes(text)) continue;
      turn.items.splice(itemIndex, 1);
      turn.compressed = true;
      return;
    }
  }
  const currentTurn = state.currentTurnId ? state.turnMap.get(state.currentTurnId) : null;
  if (currentTurn) currentTurn.compressed = true;
}

function previewFromTurns(turns) {
  for (const turn of turns) {
    for (const item of turn.items || []) {
      if (item.type === "userMessage") {
        const text = textFromContent(item.content).trim();
        if (text) return text.slice(0, 180);
      }
    }
  }
  const firstAssistant = turns.flatMap((turn) => turn.items || []).find((item) => item.type === "agentMessage" && item.text);
  return firstAssistant?.text?.slice(0, 180) || "未命名对话";
}

function getOrCreateTurn(state, turnId, timestamp = 0) {
  const id = turnId || state.currentTurnId || `turn-${state.turns.length + 1}`;
  let turn = state.turnMap.get(id);
  if (!turn) {
    turn = {
      id,
      items: [],
      itemsView: "full",
      status: "inProgress",
      error: null,
      startedAt: timestamp || state.createdAt || 0,
      completedAt: null,
      durationMs: null,
    };
    state.turnMap.set(id, turn);
    state.turns.push(turn);
  }
  state.currentTurnId = id;
  return turn;
}

function statusFromTurns(turns, updatedAt) {
  const latest = turns[turns.length - 1];
  if (!latest) return { type: "idle" };
  if (latest.status === "inProgress") {
    const ageSeconds = Math.floor(Date.now() / 1000) - (updatedAt || latest.startedAt || 0);
    return ageSeconds <= config.activeStaleSeconds ? { type: "active" } : { type: "idle" };
  }
  return { type: "idle" };
}

function usageFromPayload(payload, timestamp) {
  const info = payload?.info || {};
  const total = info.total_token_usage || null;
  const last = info.last_token_usage || null;
  if (!total && !last && !payload?.rate_limits) return null;
  return {
    total,
    last,
    modelContextWindow: info.model_context_window || null,
    rateLimits: payload.rate_limits || null,
    updatedAt: timestamp,
  };
}

function parseSessionLine(state, record) {
  if (!record) return;
  const timestamp = timestampSeconds(record.timestamp);
  const createdAt = timestampPrecise(record.timestamp) || timestamp;
  if (timestamp) {
    state.createdAt ||= timestamp;
    state.updatedAt = Math.max(state.updatedAt || 0, timestamp);
  }

  const payload = record.payload || {};
  if (record.type === "compacted") {
    // Codex writes its internal handoff summary as an assistant final_answer
    // immediately before the compaction record. It is model context, not a
    // user-facing reply, so remove it while keeping every earlier turn/item.
    removeCompactionSummary(state, payload.message);
    return;
  }
  if (record.type === "session_meta") {
    state.sessionId = payload.session_id || payload.id || state.sessionId || state.id;
    state.cwd = payload.cwd || state.cwd;
    state.name = threadNameFromPayload(payload) || state.name;
    state.cliVersion = payload.cli_version || payload.cliVersion || state.cliVersion;
    state.source = payload.source || payload.originator || state.source;
    state.modelProvider = payload.model_provider || payload.modelProvider || state.modelProvider;
    state.historyMode = payload.history_mode || payload.historyMode || state.historyMode;
    state.threadSource = payload.thread_source || payload.threadSource || state.threadSource;
    return;
  }

  if (record.type === "turn_context") {
    const turnId = payload.turn_id || payload.turnId;
    const turn = getOrCreateTurn(state, turnId, timestamp);
    state.cwd = payload.cwd || state.cwd;
    turn.startedAt ||= timestamp;
    return;
  }

  if (record.type === "response_item") {
    const turnId = payload.internal_chat_message_metadata_passthrough?.turn_id;
    if (payload.type === "custom_tool_call" && ["exec", "exec_command"].includes(payload.name)) {
      const invocation = nestedExecInvocation(payload.input);
      if (invocation?.type === "command" && invocation.command) {
        const turn = getOrCreateTurn(state, turnId, timestamp);
        const item = {
          type: "commandExecution",
          id: payload.call_id || payload.id || `${turn.id}-command-${turn.items.length}`,
          command: redactCommand(invocation.command).trim(),
          activity: commandActivity(invocation.command),
          status: "inProgress",
          exitCode: null,
          duration: null,
          createdAt,
        };
        addUniqueItem(turn, item);
        if (payload.call_id) state.toolCallMap.set(payload.call_id, item);
      } else if (invocation?.type === "edit") {
        const turn = getOrCreateTurn(state, turnId, timestamp);
        const diff = editedPatchSections(invocation.patch);
        const item = {
          type: "commandExecution",
          id: payload.call_id || payload.id || `${turn.id}-edit-${turn.items.length}`,
          command: editedFilesFromSections(diff),
          diff,
          activity: "edited",
          status: "inProgress",
          exitCode: null,
          duration: null,
          createdAt,
        };
        addUniqueItem(turn, item);
        if (payload.call_id) state.toolCallMap.set(payload.call_id, item);
      } else if (invocation?.type === "resume" && invocation.sessionId !== null) {
        const item = state.sessionCommandMap.get(invocation.sessionId);
        if (item && payload.call_id) state.toolCallMap.set(payload.call_id, item);
      }
      return;
    }
    if (payload.type === "custom_tool_call" && payload.name === "apply_patch") {
      const turn = getOrCreateTurn(state, turnId, timestamp);
      const diff = editedPatchSections(payload.input);
      const item = {
        type: "commandExecution",
        id: payload.call_id || payload.id || `${turn.id}-edit-${turn.items.length}`,
        command: editedFilesFromSections(diff),
        diff,
        activity: "edited",
        status: "inProgress",
        exitCode: null,
        duration: null,
        createdAt,
      };
      addUniqueItem(turn, item);
      if (payload.call_id) state.toolCallMap.set(payload.call_id, item);
      return;
    }
    if (payload.type === "custom_tool_call_output") {
      const item = state.toolCallMap.get(payload.call_id);
      if (item) {
        const result = customToolResult(payload.output);
        item.status = result.status;
        item.exitCode = result.exitCode;
        item.duration = result.duration || item.duration;
        if (result.sessionId !== null) state.sessionCommandMap.set(result.sessionId, item);
      }
      return;
    }
    if (payload.type === "function_call" && ["exec_command", "exec", "shell", "shell_command"].includes(payload.name)) {
      const args = typeof payload.arguments === "object"
        ? payload.arguments
        : (safeJson(payload.arguments) || {});
      const command = redactCommand(args.cmd || args.command || args.input).trim();
      if (!command) return;
      const turn = getOrCreateTurn(state, turnId, timestamp);
      const item = {
        type: "commandExecution",
        id: payload.call_id || payload.id || `${turn.id}-command-${turn.items.length}`,
        command,
        activity: commandActivity(command),
        status: "inProgress",
        exitCode: null,
        duration: null,
        createdAt,
      };
      addUniqueItem(turn, item);
      if (payload.call_id) state.toolCallMap.set(payload.call_id, item);
      return;
    }
    if (payload.type === "function_call_output") {
      const item = state.toolCallMap.get(payload.call_id);
      if (item) Object.assign(item, commandResult(payload.output));
      return;
    }
    if (payload.type !== "message" || payload.role !== "assistant") return;
    const text = outputTextFromResponse(payload);
    if (!text || text.startsWith("<turn_aborted>")) return;
    const turn = getOrCreateTurn(state, turnId, timestamp);
    addUniqueItem(turn, {
      type: "agentMessage",
      id: payload.id || `${turn.id}-${payload.role}-${turn.items.length}`,
      text,
      phase: payload.phase || null,
      createdAt,
    });
    return;
  }

  if (record.type !== "event_msg") return;
  state.name = threadNameFromPayload(payload) || state.name;
  if (payload.type === "token_count") {
    state.usage = usageFromPayload(payload, timestamp);
    return;
  }
  if (payload.type === "thread_settings_applied") {
    const settings = payload.thread_settings || {};
    state.cwd = settings.cwd || state.cwd;
    state.model = settings.model || state.model;
    state.modelProvider = settings.model_provider_id || state.modelProvider;
    return;
  }
  if (payload.type === "task_started") {
    const turn = getOrCreateTurn(state, payload.turn_id, timestampSeconds(payload.started_at) || timestamp);
    turn.status = "inProgress";
    turn.startedAt = timestampSeconds(payload.started_at) || turn.startedAt || timestamp;
    turn.completedAt = null;
    turn.error = null;
    return;
  }
  if (payload.type === "task_complete") {
    const turn = getOrCreateTurn(state, payload.turn_id, timestampSeconds(payload.started_at) || timestamp);
    turn.completedAt = timestampSeconds(payload.completed_at) || timestamp;
    turn.durationMs = payload.duration_ms ?? turn.durationMs;
    turn.error = errorFromPayload(payload.error);
    turn.status = turn.error ? "failed" : "completed";
    if (payload.last_agent_message) {
      addUniqueItem(turn, {
        type: "agentMessage",
        id: `${turn.id}-last-agent-message`,
        text: String(payload.last_agent_message),
        phase: "final_answer",
        createdAt: timestampPrecise(payload.completed_at) || createdAt,
      });
    }
    return;
  }
  if (payload.type === "turn_aborted") {
    const turn = getOrCreateTurn(state, payload.turn_id, timestampSeconds(payload.started_at) || timestamp);
    turn.completedAt = timestampSeconds(payload.completed_at) || timestamp;
    turn.durationMs = payload.duration_ms ?? turn.durationMs;
    turn.status = "interrupted";
    return;
  }
  if (payload.type === "user_message") {
    const turn = getOrCreateTurn(state, payload.turn_id || state.currentTurnId, timestamp);
    const text = payload.message || "";
    addUniqueItem(turn, {
      type: "userMessage",
      id: `${turn.id}-event-user-${turn.items.length}`,
      content: [{ type: "text", text }],
      createdAt,
    });
    return;
  }
  if (payload.type === "agent_message") {
    const turn = getOrCreateTurn(state, payload.turn_id || state.currentTurnId, timestamp);
    addUniqueItem(turn, {
      type: "agentMessage",
      id: `${turn.id}-event-agent-${turn.items.length}`,
      text: payload.message || "",
      phase: payload.phase || "commentary",
      createdAt,
    });
  }
}

export function threadIdFromPath(filePath) {
  const match = path.basename(filePath).match(SESSION_FILE_RE);
  return match?.[1] || null;
}

export async function findSessionFiles(root = config.codexSessionsDir) {
  const results = [];
  async function walk(dir) {
    let entries = [];
    try { entries = await fs.readdir(dir, { withFileTypes: true }); } catch { return; }
    await Promise.all(entries.map(async (entry) => {
      const fullPath = path.join(dir, entry.name);
      if (entry.isDirectory()) return walk(fullPath);
      if (entry.isFile() && entry.name.endsWith(".jsonl") && threadIdFromPath(fullPath)) results.push(fullPath);
    }));
  }
  await walk(root);
  return results;
}

export async function readCliThread(filePath) {
  const idFromPath = threadIdFromPath(filePath);
  const stat = await fs.stat(filePath);
  const state = {
    id: idFromPath,
    cwd: null,
    cliVersion: null,
    source: "codex-cli",
    modelProvider: null,
    model: null,
    historyMode: "legacy",
    threadSource: "cli-local",
    sessionId: idFromPath,
    createdAt: 0,
    updatedAt: stat.mtimeMs / 1000,
    currentTurnId: null,
    turnMap: new Map(),
    toolCallMap: new Map(),
    sessionCommandMap: new Map(),
    turns: [],
    usage: null,
  };
  const raw = await fs.readFile(filePath, "utf8");
  for (const line of raw.split("\n")) {
    if (line.trim()) parseSessionLine(state, safeJson(line));
  }
  const indexedName = (await readSessionIndexNames()).get(state.id);
  if (indexedName) state.name = indexedName;
  const createdAt = state.createdAt || stat.birthtimeMs / 1000 || state.updatedAt;
  const updatedAt = Math.max(state.updatedAt || 0, stat.mtimeMs / 1000);
  const thread = {
    id: state.id,
    extra: null,
    sessionId: state.sessionId || state.id,
    forkedFromId: null,
    parentThreadId: null,
    preview: previewFromTurns(state.turns),
    ephemeral: false,
    isPinned: false,
    historyMode: state.historyMode,
    modelProvider: state.modelProvider,
    model: state.model,
    createdAt,
    updatedAt,
    syncRevision: `${stat.mtimeMs}:${stat.size}`,
    recencyAt: updatedAt,
    status: statusFromTurns(state.turns, updatedAt),
    path: filePath,
    cwd: state.cwd || "未指定项目目录",
    cliVersion: state.cliVersion,
    source: state.source || "codex-cli",
    canAcceptDirectInput: true,
    threadSource: state.threadSource || "cli-local",
    agentNickname: null,
    agentRole: null,
    gitInfo: null,
    name: state.name || null,
    usage: state.usage,
    turns: state.turns,
  };
  return { thread, turns: state.turns };
}

export async function readArchiveSet() {
  try {
    const data = JSON.parse(await fs.readFile(ARCHIVE_FILE, "utf8"));
    return new Set(Array.isArray(data.archivedThreadIds) ? data.archivedThreadIds : []);
  } catch {
    return new Set();
  }
}

export async function writeArchiveSet(archiveSet) {
  await fs.mkdir(path.dirname(ARCHIVE_FILE), { recursive: true });
  await fs.writeFile(ARCHIVE_FILE, JSON.stringify({
    archivedThreadIds: [...archiveSet].sort(),
    updatedAt: new Date().toISOString(),
  }, null, 2));
}

export async function archiveCliThread(threadId) {
  const archiveSet = await readArchiveSet();
  archiveSet.add(threadId);
  await writeArchiveSet(archiveSet);
  return { archived: true, threadId };
}

export async function listCliThreads({ archived = false } = {}) {
  const archiveSet = await readArchiveSet();
  const files = await findSessionFiles();
  const settled = await Promise.allSettled(files.map((file) => readCliThread(file)));
  return settled
    .filter((item) => item.status === "fulfilled")
    .map((item) => item.value.thread)
    .filter((thread) => config.includeSubagents || thread.threadSource !== "subagent")
    .filter((thread) => archived ? archiveSet.has(thread.id) : !archiveSet.has(thread.id))
    .sort((a, b) => (b.updatedAt || 0) - (a.updatedAt || 0));
}

export async function readCliThreadById(threadId) {
  const files = await findSessionFiles();
  const matches = files.filter((candidate) => threadIdFromPath(candidate) === threadId);
  if (matches.length === 0) {
    const error = new Error("CLI session not found");
    error.status = 404;
    throw error;
  }
  const stats = await Promise.all(matches.map(async (candidate) => ({
    file: candidate,
    stat: await fs.stat(candidate),
  })));
  const newest = stats.sort((left, right) => right.stat.mtimeMs - left.stat.mtimeMs)[0];
  return readCliThread(newest.file);
}

import test from "node:test";
import assert from "node:assert/strict";
import fs from "node:fs/promises";
import os from "node:os";
import path from "node:path";
import { listModelsViaStdio } from "../src/app-server-stdio.js";
import { readCliThread } from "../src/cli-sessions.js";
import { daemonPaths, isProcessRunning, readPidRecord } from "../src/daemon.js";
import { isPathInside, normalizeAllowedPath } from "../src/file-roots.js";

test("project has a package and a safe default workspace root", async () => {
  const packageJson = await import("../package.json", { with: { type: "json" } });
  assert.equal(packageJson.default.name, "cloudex");
  assert.equal(path.isAbsolute(process.cwd()), true);
});

test("file root checks allow project descendants but reject sibling projects", () => {
  const root = path.join(os.tmpdir(), "cloudex-project-a");
  const child = path.join(root, "Sources", "Feature.swift");
  const sibling = path.join(os.tmpdir(), "cloudex-project-b", "Feature.swift");

  assert.equal(isPathInside(root, root), true);
  assert.equal(isPathInside(root, child), true);
  assert.equal(isPathInside(root, sibling), false);
  assert.equal(normalizeAllowedPath(child, { defaultPath: root, roots: [root] }), child);
  assert.throws(
    () => normalizeAllowedPath(sibling, { defaultPath: root, roots: [root] }),
    (error) => error.status === 403,
  );
});

test("daemon state uses a PID file and detects the current process", async () => {
  const directory = await fs.mkdtemp(path.join(os.tmpdir(), "cloudex-daemon-"));
  try {
    const paths = daemonPaths(directory);
    assert.equal(paths.pidFile, path.join(directory, "server.pid"));
    assert.equal(isProcessRunning(process.pid), true);
    assert.equal(await readPidRecord(paths.pidFile), null);
    await fs.writeFile(paths.pidFile, JSON.stringify({ pid: process.pid, startedAt: "test" }));
    assert.deepEqual(await readPidRecord(paths.pidFile), { pid: process.pid, startedAt: "test" });
  } finally {
    await fs.rm(directory, { recursive: true, force: true });
  }
});

test("stdio app-server model fallback performs initialize and model/list", async () => {
  const directory = await fs.mkdtemp(path.join(os.tmpdir(), "cloudex-model-server-"));
  const scriptPath = path.join(directory, "fake-app-server.mjs");
  const script = [
    'import readline from "node:readline";',
    'const input = readline.createInterface({ input: process.stdin });',
    'input.on("line", (line) => {',
    '  const request = JSON.parse(line);',
    '  if (request.method === "initialize") process.stdout.write(JSON.stringify({ jsonrpc: "2.0", id: request.id, result: {} }) + "\\n");',
    '  if (request.method === "model/list") process.stdout.write(JSON.stringify({ jsonrpc: "2.0", id: request.id, result: { data: [{ id: "gpt-test", model: "gpt-test" }] } }) + "\\n");',
    '});',
  ].join("\n");

  try {
    await fs.writeFile(scriptPath, script, "utf8");
    const result = await listModelsViaStdio({
      codexBin: process.execPath,
      commandArgs: [scriptPath],
      timeoutMs: 3000,
    });
    assert.deepEqual(result.data, [{ id: "gpt-test", model: "gpt-test" }]);
  } finally {
    await fs.rm(directory, { recursive: true, force: true });
  }
});

test("CLI session parser restores commands from JSON-style exec wrappers", async () => {
  const directory = await fs.mkdtemp(path.join(os.tmpdir(), "cloudex-cli-session-"));
  const sessionPath = path.join(
    directory,
    "rollout-2026-08-04T10-00-00-019fca5a-eba0-7081-abb3-04f985429858.jsonl",
  );
  const turnId = "019fcaa0-544a-7f40-84d2-5fc356d90607";
  const records = [
    {
      timestamp: "2026-08-04T02:40:00.000Z",
      type: "turn_context",
      payload: { turn_id: turnId, cwd: "/tmp/project" },
    },
    {
      timestamp: "2026-08-04T02:40:01.000Z",
      type: "response_item",
      payload: {
        type: "custom_tool_call",
        id: "tool-call",
        call_id: "call-search",
        name: "exec",
        input: 'const r = await tools.exec_command({"cmd":"rg -n \\\"scrollTo\\\" ContentView.swift","workdir":"/tmp/project"});',
        internal_chat_message_metadata_passthrough: { turn_id: turnId },
      },
    },
    {
      timestamp: "2026-08-04T02:40:02.000Z",
      type: "response_item",
      payload: {
        type: "custom_tool_call_output",
        call_id: "call-search",
        output: [{ type: "input_text", text: '{"exit_code":0,"wall_time_seconds":0.1,"output":""}' }],
      },
    },
  ];

  try {
    await fs.writeFile(sessionPath, `${records.map((record) => JSON.stringify(record)).join("\n")}\n`);
    const parsed = await readCliThread(sessionPath);
    const command = parsed.turns[0].items.find((item) => item.type === "commandExecution");
    assert.equal(command?.command, 'rg -n "scrollTo" ContentView.swift');
    assert.equal(command?.activity, "explored");
    assert.equal(command?.status, "completed");
  } finally {
    await fs.rm(directory, { recursive: true, force: true });
  }
});

test("CLI session parser preserves history and hides compaction handoff summaries", async () => {
  const directory = await fs.mkdtemp(path.join(os.tmpdir(), "cloudex-cli-compaction-"));
  const sessionPath = path.join(
    directory,
    "rollout-2026-08-04T11-00-00-019fca5a-eba0-7081-abb3-04f985429858.jsonl",
  );
  const turnId = "019fcaa0-544a-7f40-84d2-5fc356d90607";
  const handoff = "## Handoff summary\n\n### Current task\nInternal continuation state";
  const records = [
    {
      timestamp: "2026-08-04T03:00:00.000Z",
      type: "turn_context",
      payload: { turn_id: turnId, cwd: "/tmp/project" },
    },
    {
      timestamp: "2026-08-04T03:00:01.000Z",
      type: "event_msg",
      payload: { type: "user_message", turn_id: turnId, message: "Keep this question" },
    },
    {
      timestamp: "2026-08-04T03:00:02.000Z",
      type: "response_item",
      payload: {
        type: "message",
        id: "commentary-before-compaction",
        role: "assistant",
        phase: "commentary",
        content: [{ type: "output_text", text: "Keep this progress update" }],
        internal_chat_message_metadata_passthrough: { turn_id: turnId },
      },
    },
    {
      timestamp: "2026-08-04T03:00:03.000Z",
      type: "response_item",
      payload: {
        type: "message",
        id: "internal-handoff",
        role: "assistant",
        phase: "final_answer",
        content: [{ type: "output_text", text: handoff }],
        internal_chat_message_metadata_passthrough: { turn_id: turnId },
      },
    },
    {
      timestamp: "2026-08-04T03:00:03.010Z",
      type: "compacted",
      payload: {
        message: `Another language model started to solve this problem.\n${handoff}`,
        replacement_history: [],
        window_id: "window-2",
      },
    },
    {
      timestamp: "2026-08-04T03:00:04.000Z",
      type: "response_item",
      payload: {
        type: "message",
        id: "real-final-answer",
        role: "assistant",
        phase: "final_answer",
        content: [{ type: "output_text", text: "This is the real reply" }],
        internal_chat_message_metadata_passthrough: { turn_id: turnId },
      },
    },
  ];

  try {
    await fs.writeFile(sessionPath, `${records.map((record) => JSON.stringify(record)).join("\n")}\n`);
    const parsed = await readCliThread(sessionPath);
    const items = parsed.turns[0].items;
    assert.equal(parsed.turns[0].compressed, true);
    assert.equal(items.some((item) => item.text === handoff), false);
    assert.equal(items.some((item) => item.text === "Keep this progress update"), true);
    assert.equal(items.some((item) => item.text === "This is the real reply"), true);
    assert.equal(items.some((item) => item.type === "userMessage"), true);
  } finally {
    await fs.rm(directory, { recursive: true, force: true });
  }
});

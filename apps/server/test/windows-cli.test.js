import test from "node:test";
import assert from "node:assert/strict";
import fs from "node:fs/promises";
import os from "node:os";
import path from "node:path";
import { readCliThread } from "../src/cli-sessions.js";
import {
  buildCliArgs,
  execEventToAppMessage,
  execItemToAppItem,
} from "../src/windows-cli.js";

test("windows CLI args resume an existing session with model, effort, and images", () => {
  const args = buildCliArgs({
    resume: true,
    threadId: "019fcc32-be0f-7be0-8d6e-185690b6c234",
    prompt: "继续检查日志",
    files: [{ path: "C:\\tmp\\screenshot.png" }],
    model: "gpt-5.5",
    effort: "high",
    sandbox: "workspace-write",
    approvalPolicy: "on-request",
    approvalsReviewer: "auto_review",
  });
  assert.deepEqual(args, [
    "exec",
    "resume",
    "--json",
    "019fcc32-be0f-7be0-8d6e-185690b6c234",
    "-m",
    "gpt-5.5",
    "-c",
    'model_reasoning_effort="high"',
    "-c",
    'sandbox_mode="workspace-write"',
    "-c",
    'approval_policy="on-request"',
    "-c",
    'approvals_reviewer="auto_review"',
    "-i",
    "C:\\tmp\\screenshot.png",
    "继续检查日志",
  ]);
});

test("windows CLI args start a new session in the requested cwd", () => {
  const args = buildCliArgs({
    resume: false,
    cwd: "C:\\Users\\win\\Documents\\GitHub\\Cloudex",
    prompt: "hello",
    model: "gpt-5.5",
  });
  assert.deepEqual(args, [
    "exec",
    "--json",
    "-C",
    "C:\\Users\\win\\Documents\\GitHub\\Cloudex",
    "-m",
    "gpt-5.5",
    "hello",
  ]);
});

test("exec JSONL command execution events map to live app notifications", () => {
  const started = execEventToAppMessage({
    type: "item.started",
    item: {
      id: "item_1",
      type: "command_execution",
      command: "bash -lc ls",
      aggregated_output: "",
      status: "in_progress",
    },
  }, { threadId: "019fcc32", turnId: "win-turn-1" });
  assert.equal(started.method, "item/started");
  assert.equal(started.params.threadId, "019fcc32");
  assert.equal(started.params.turnId, "win-turn-1");
  assert.equal(started.params.itemId, "item_1");
  assert.equal(started.params.item.type, "commandExecution");
  assert.equal(started.params.item.command, "bash -lc ls");
  assert.equal(started.params.item.status, "inProgress");
  assert.equal(started.params.item.exitCode, null);

  const completed = execEventToAppMessage({
    type: "item.completed",
    item: {
      id: "item_1",
      type: "command_execution",
      command: "bash -lc ls",
      aggregated_output: "README.md\n",
      exit_code: 0,
      status: "completed",
    },
  }, { threadId: "019fcc32", turnId: "win-turn-1" });
  assert.equal(completed.method, "item/completed");
  assert.equal(completed.params.item.status, "completed");
  assert.equal(completed.params.item.exitCode, 0);
  assert.equal(completed.params.item.aggregatedOutput, "README.md\n");
});

test("exec JSONL agent message and file change items map to app protocol", () => {
  const agent = execEventToAppMessage({
    type: "item.completed",
    item: { id: "item_3", type: "agent_message", text: "Done." },
  }, { threadId: "019fcc32", turnId: "win-turn-1" });
  assert.equal(agent.method, "item/completed");
  assert.equal(agent.params.item.type, "agentMessage");
  assert.equal(agent.params.item.text, "Done.");

  const fileChange = execItemToAppItem({
    id: "item_4",
    type: "file_change",
    changes: [{ path: "src/app.js", kind: "update" }],
    status: "completed",
  });
  assert.equal(fileChange.type, "fileChange");
  assert.equal(fileChange.activity, "edited");
  assert.equal(fileChange.status, "completed");
  assert.deepEqual(fileChange.changes, [{ path: "src/app.js", kind: "update" }]);
});

test("exec JSONL turn lifecycle events carry a stable thread and turn id", () => {
  const thread = execEventToAppMessage({
    type: "thread.started",
    thread_id: "019fcc32-be0f-7be0-8d6e-185690b6c234",
  });
  assert.equal(thread.method, "thread/started");
  assert.equal(thread.params.threadId, "019fcc32-be0f-7be0-8d6e-185690b6c234");

  const started = execEventToAppMessage(
    { type: "turn.started" },
    { threadId: "019fcc32", turnId: "win-turn-1" },
  );
  assert.equal(started.method, "turn/started");
  assert.equal(started.params.turnId, "win-turn-1");

  const completed = execEventToAppMessage(
    {
      type: "turn.completed",
      usage: {
        input_tokens: 24763,
        cached_input_tokens: 24448,
        output_tokens: 122,
        reasoning_output_tokens: 10,
      },
    },
    { threadId: "019fcc32", turnId: "win-turn-1" },
  );
  assert.equal(completed.method, "turn/completed");
  assert.equal(completed.params.turn.status, "completed");
  assert.equal(completed.params.usage.inputTokens, 24763);
  assert.equal(completed.params.usage.outputTokens, 122);

  const failed = execEventToAppMessage(
    { type: "turn.failed", error: { message: "boom" } },
    { threadId: "019fcc32", turnId: "win-turn-1" },
  );
  assert.equal(failed.method, "turn/failed");
  assert.equal(failed.params.turn.error.message, "boom");
  assert.equal(execEventToAppMessage({ type: "unknown.event" }), null);
});

test("CLI session parser handles function_call shell_command records", async () => {
  const directory = await fs.mkdtemp(path.join(os.tmpdir(), "cloudex-cli-shell-command-"));
  const sessionPath = path.join(
    directory,
    "rollout-2026-08-04T17-55-05-019fcc32-be0f-7be0-8d6e-185690b6c234.jsonl",
  );
  const turnId = "019fcc33-438a-71c1-b4bc-af5aedec6897";
  const callId = "call_00_W4XUXvKjWitWacFBbLEq4062";
  const records = [
    {
      timestamp: "2026-08-04T09:55:06.000Z",
      type: "turn_context",
      payload: { turn_id: turnId, cwd: "C:\\project" },
    },
    {
      timestamp: "2026-08-04T09:55:07.000Z",
      type: "response_item",
      payload: {
        type: "function_call",
        id: "fc-1",
        name: "shell_command",
        arguments: '{"command": "rg -n \\"TODO\\" src"}',
        call_id: callId,
        internal_chat_message_metadata_passthrough: { turn_id: turnId },
      },
    },
    {
      timestamp: "2026-08-04T09:55:08.000Z",
      type: "response_item",
      payload: {
        type: "function_call_output",
        id: "fco-1",
        call_id: callId,
        output: "Exit code: 0\nWall time: 0.3 seconds\nOutput:\nno matches",
      },
    },
  ];

  try {
    await fs.writeFile(sessionPath, `${records.map((record) => JSON.stringify(record)).join("\n")}\n`);
    const parsed = await readCliThread(sessionPath);
    const command = parsed.turns[0].items.find((item) => item.type === "commandExecution");
    assert.equal(command?.command, 'rg -n "TODO" src');
    assert.equal(command?.activity, "explored");
    assert.equal(command?.status, "completed");
    assert.equal(command?.exitCode, 0);
  } finally {
    await fs.rm(directory, { recursive: true, force: true });
  }
});

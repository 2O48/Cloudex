import test from "node:test";
import assert from "node:assert/strict";
import fs from "node:fs/promises";
import os from "node:os";
import path from "node:path";
import { readCliThread } from "../src/cli-sessions.js";
import { buildCliArgs } from "../src/windows-cli.js";

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

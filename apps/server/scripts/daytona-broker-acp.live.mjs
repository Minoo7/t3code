#!/usr/bin/env node
// Opt-in live smoke for the experimental broker ACP adapter.
import { spawn, execFile } from "node:child_process";
import { randomUUID } from "node:crypto";
import { rm } from "node:fs/promises";
import { createInterface } from "node:readline";
import { promisify } from "node:util";

const execute = promisify(execFile);
const root = process.env.PLANA_BROKER_ROOT;
const bun = process.env.PLANA_BROKER_BUN ?? "bun";
if (!root) throw new Error("Set PLANA_BROKER_ROOT to the built broker checkout");
const state = `/tmp/t3-broker-acp-live-${randomUUID()}.json`;
const child = spawn(process.execPath, [new URL("./daytona-broker-acp.mjs", import.meta.url).pathname], {
  env: { ...process.env, PLANA_BROKER_ACP_STATE: state },
  stdio: ["pipe", "pipe", "pipe"],
});
const seen = [];
const waiters = [];
let taskId;
createInterface({ input: child.stdout }).on("line", (line) => {
  const message = JSON.parse(line);
  seen.push(message);
  const match = message.params?.update?.content?.text?.match(/Daytona task ([0-9a-f-]{36})/);
  if (match) taskId = match[1];
  for (const resolve of waiters.splice(0)) resolve();
});
child.stderr.on("data", (data) => process.stderr.write(data));
const send = (id, method, params = {}) => child.stdin.write(JSON.stringify({ jsonrpc: "2.0", id, method, params }) + "\n");
async function receive(id) {
  const until = Date.now() + 180_000;
  for (;;) {
    const found = seen.find((message) => message.id === id);
    if (found) return found;
    if (Date.now() >= until) throw new Error(`ACP response ${id} timed out`);
    await Promise.race([
      new Promise((resolve) => waiters.push(resolve)),
      new Promise((resolve) => setTimeout(resolve, 1000)),
    ]);
  }
}
try {
  send(1, "initialize");
  if ((await receive(1)).error) throw new Error("ACP initialization failed");
  send(2, "authenticate", { methodId: "none" });
  if ((await receive(2)).error) throw new Error("ACP authentication failed");
  send(3, "session/new", { cwd: "/tmp", mcpServers: [] });
  const sessionId = (await receive(3)).result?.sessionId;
  if (!sessionId) throw new Error("ACP session was not created");
  send(4, "session/prompt", {
    sessionId,
    prompt: [{ type: "text", text: "Write native-acp-proof.txt containing exactly NATIVE_ACP_OK and a newline. Report what you did." }],
  });
  const result = await receive(4);
  if (result.error) throw new Error(result.error.message);
  if (!taskId) throw new Error("ACP adapter did not report a broker task ID");
  console.log(JSON.stringify({
    taskId,
    stopReason: result.result.stopReason,
    messages: seen.filter((message) => message.method === "session/update").map((message) => message.params.update.content?.text),
  }));
  const archive = JSON.parse((await execute(bun, [`${root}/bin/run.js`, "broker", "archive", taskId], { cwd: root })).stdout);
  const disposed = JSON.parse((await execute(bun, [`${root}/bin/run.js`, "broker", "dispose", taskId], { cwd: root })).stdout);
  console.log(JSON.stringify({ archived: archive.status, disposed: disposed.status, artifact: archive.artifactPath }));
} finally {
  child.stdin.end();
  await rm(state, { force: true });
}

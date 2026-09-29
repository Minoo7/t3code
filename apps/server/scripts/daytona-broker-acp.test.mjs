import assert from "node:assert/strict";
import { spawn } from "node:child_process";
import { mkdtemp, mkdir, readFile, rm, writeFile } from "node:fs/promises";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { createInterface } from "node:readline";
import { test } from "node:test";

test("ACP session streams a broker result and resumes the same task", async () => {
  const root = await mkdtemp(join(tmpdir(), "broker-acp-test-"));
  const brokerRoot = join(root, "broker");
  await mkdir(join(brokerRoot, "bin"), { recursive: true });
  await writeFile(join(brokerRoot, "bin/run.js"), `
import { appendFileSync, readFileSync } from "node:fs";
const [, , , action, maybeId, ...rest] = process.argv;
const args = process.argv.slice(4);
appendFileSync(process.env.BROKER_TEST_CALLS, JSON.stringify({ action, args }) + "\\n");
if (action === "start" || action === "resume") {
  const prompt = readFileSync(args[args.indexOf("--prompt-file") + 1], "utf8");
  console.log(JSON.stringify({ id: "11111111-1111-4111-8111-111111111111", status: "running", prompt }));
} else if (action === "wait") {
  console.log(JSON.stringify({ timedOut: false, task: { status: "completed" }, finalMessage: "WORKER_DONE" }));
} else throw new Error("Unexpected action " + action);
`);
  const child = spawn(process.execPath, [new URL("./daytona-broker-acp.mjs", import.meta.url).pathname], {
    env: {
      ...process.env,
      PLANA_BROKER_BUN: process.execPath,
      PLANA_BROKER_ROOT: brokerRoot,
      PLANA_BROKER_ACP_STATE: join(root, "sessions.json"),
      BROKER_TEST_CALLS: join(root, "calls.jsonl"),
    },
    stdio: ["pipe", "pipe", "pipe"],
  });
  const messages = [];
  const readers = [];
  const lines = createInterface({ input: child.stdout });
  lines.on("line", (line) => {
    messages.push(JSON.parse(line));
    for (const resolve of readers.splice(0)) resolve();
  });
  const receive = async (predicate) => {
    for (;;) {
      const found = messages.find(predicate);
      if (found) return found;
      await new Promise((resolve, reject) => {
        const timeout = setTimeout(() => reject(new Error("ACP response timed out")), 5000);
        readers.push(() => { clearTimeout(timeout); resolve(); });
      });
    }
  };
  const send = (id, method, params = {}) =>
    child.stdin.write(JSON.stringify({ jsonrpc: "2.0", id, method, params }) + "\n");
  try {
    send(1, "initialize");
    assert.equal((await receive((message) => message.id === 1)).result.protocolVersion, 1);
    send(5, "cursor/list_available_models");
    assert.equal((await receive((message) => message.id === 5)).result.models[0].value, "broker-default");
    send(2, "session/new", { cwd: "/tmp", mcpServers: [] });
    const sessionId = (await receive((message) => message.id === 2)).result.sessionId;
    send(6, "session/set_config_option", { sessionId, configId: "model", value: "broker-default" });
    assert.deepEqual((await receive((message) => message.id === 6)).result, { configOptions: [] });
    send(3, "session/prompt", { sessionId, prompt: [{ type: "text", text: "first turn" }] });
    assert.equal((await receive((message) => message.id === 3)).result.stopReason, "end_turn");
    assert.equal((await receive((message) => message.method === "session/update" && message.params?.update?.content?.text === "WORKER_DONE")).params.sessionId, sessionId);
    send(4, "session/prompt", { sessionId, prompt: [{ type: "text", text: "follow-up" }] });
    assert.equal((await receive((message) => message.id === 4)).result.stopReason, "end_turn");
    const calls = (await readFile(join(root, "calls.jsonl"), "utf8")).trim().split("\n").map(JSON.parse);
    assert.deepEqual(calls.map((call) => call.action), ["start", "wait", "resume", "wait"]);
    assert.equal(calls[2].args[0], "11111111-1111-4111-8111-111111111111");
    assert.equal(JSON.parse(await readFile(join(root, "sessions.json"), "utf8"))[sessionId].taskId, calls[2].args[0]);
  } finally {
    child.stdin.end();
    await new Promise((resolve) => child.once("exit", resolve));
    await rm(root, { recursive: true, force: true });
  }
});

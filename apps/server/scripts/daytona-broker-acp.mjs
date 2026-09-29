#!/usr/bin/env node
// Experimental ACP provider for the Plana Box Daytona broker. Run on the control host.
import { execFile } from "node:child_process";
import { randomUUID } from "node:crypto";
import { mkdir, readFile, rename, rm, writeFile } from "node:fs/promises";
import { homedir, tmpdir } from "node:os";
import { dirname, join } from "node:path";
import { createInterface } from "node:readline";
import { promisify } from "node:util";

const exec = promisify(execFile);
const bun = process.env.PLANA_BROKER_BUN ?? "bun";
const brokerRoot = process.env.PLANA_BROKER_ROOT;
const statePath = process.env.PLANA_BROKER_ACP_STATE ??
  join(homedir(), ".local/share/plana-box/broker/acp-sessions.json");
const repo = process.env.PLANA_BROKER_REPO;
const base = process.env.PLANA_BROKER_BASE ?? "main";
const retention = process.env.PLANA_BROKER_RETENTION ?? "auto";
if (!new Set(["auto", "manual"]).has(retention)) throw new Error("PLANA_BROKER_RETENTION must be auto or manual");
const sessions = new Map();

const send = (value) => process.stdout.write(`${JSON.stringify({ jsonrpc: "2.0", ...value })}\n`);
const reply = (id, result) => send({ id, result });
const fail = (id, error) => send({ id, error: { code: -32603, message: String(error?.message ?? error) } });
const announce = (sessionId, text) => send({
  method: "session/update",
  params: { sessionId, update: { sessionUpdate: "agent_message_chunk", content: { type: "text", text } } },
});

async function persist() {
  await mkdir(dirname(statePath), { recursive: true, mode: 0o700 });
  const temporary = `${statePath}.${randomUUID()}.tmp`;
  await writeFile(temporary, JSON.stringify(Object.fromEntries(sessions)), { mode: 0o600 });
  await rename(temporary, statePath);
}

async function broker(action, id, prompt) {
  if (!brokerRoot) throw new Error("PLANA_BROKER_ROOT must point to the built broker checkout");
  const args = [join(brokerRoot, "bin/run.js"), "broker", action];
  if (id) args.push(id);
  if (action === "start") {
    args.push("--kind", "implementation", "--retention", retention);
    if (repo) args.push("--repo", repo, "--base", base);
  }
  let promptPath;
  try {
    if (prompt !== undefined) {
      promptPath = join(tmpdir(), `plana-broker-acp-${randomUUID()}.txt`);
      await writeFile(promptPath, prompt, { mode: 0o600 });
      args.push("--prompt-file", promptPath);
    }
    if (action === "wait") args.push("--timeout", "30");
    const { stdout } = await exec(bun, args, { cwd: brokerRoot, maxBuffer: 8 * 1024 * 1024 });
    return JSON.parse(stdout);
  } finally {
    if (promptPath) await rm(promptPath, { force: true });
  }
}

const textOf = (prompt) => Array.isArray(prompt)
  ? prompt.filter((part) => part?.type === "text").map((part) => part.text).join("\n").trim()
  : "";

async function handle(message) {
  const { id, method, params = {} } = message;
  try {
    switch (method) {
      case "initialize":
        reply(id, {
          protocolVersion: 1,
          agentInfo: { name: "plana-daytona-broker", version: "0.1.0" },
          agentCapabilities: { loadSession: true, sessionCapabilities: { resume: {} } },
          authMethods: [],
        });
        return;
      case "authenticate":
        reply(id, {});
        return;
      case "cursor/list_available_models":
        reply(id, { models: [{ value: "broker-default", name: "Daytona broker worker" }] });
        return;
      case "session/new": {
        const sessionId = randomUUID();
        sessions.set(sessionId, { taskId: null });
        await persist();
        reply(id, { sessionId });
        return;
      }
      case "session/load":
      case "session/resume":
        if (!sessions.has(params.sessionId)) throw new Error("Unknown broker session");
        reply(id, {});
        return;
      case "session/prompt": {
        const session = sessions.get(params.sessionId);
        if (!session) throw new Error("Unknown broker session");
        const prompt = textOf(params.prompt);
        if (!prompt) throw new Error("Prompt must contain text");
        const task = session.taskId
          ? await broker("resume", session.taskId, prompt)
          : await broker("start", null, prompt);
        session.taskId = task.id;
        await persist();
        announce(params.sessionId, `Daytona task ${task.id} started.\n`);
        for (;;) {
          const result = await broker("wait", task.id);
          if (result.timedOut) continue;
          const final = result.finalMessage ?? result.task?.finalMessage ?? result.task?.error ?? "Worker ended without a final message.";
          announce(params.sessionId, final);
          reply(id, { stopReason: "end_turn" });
          return;
        }
      }
      case "session/cancel": {
        const taskId = sessions.get(params.sessionId)?.taskId;
        if (taskId) await broker("stop", taskId).catch(() => {});
        if (id !== undefined) reply(id, {});
        return;
      }
      case "session/set_model":
      case "session/set_mode":
        reply(id, {});
        return;
      case "session/set_config_option":
        reply(id, { configOptions: [] });
        return;
      default:
        if (id !== undefined) send({ id, error: { code: -32601, message: `Method not found: ${method}` } });
    }
  } catch (error) {
    if (id !== undefined) fail(id, error);
  }
}

try {
  const persisted = JSON.parse(await readFile(statePath, "utf8"));
  for (const [id, value] of Object.entries(persisted)) sessions.set(id, value);
} catch (error) {
  if (error.code !== "ENOENT") throw error;
}

for await (const line of createInterface({ input: process.stdin })) {
  if (!line.trim()) continue;
  try { void handle(JSON.parse(line)); }
  catch (error) { process.stderr.write(`Invalid ACP input: ${error}\n`); }
}

#!/usr/bin/env node
// Temporary Cursor-compatible launcher for testing the broker in an isolated T3 server.
import { spawn } from "node:child_process";
import { fileURLToPath } from "node:url";

const args = process.argv.slice(2);
if (args[0] === "about") {
  process.stdout.write(JSON.stringify({ cliVersion: "2026.09.29", userEmail: "daytona-broker@local" }) + "\n");
} else if (args.at(-1) === "acp") {
  const bridge = fileURLToPath(new URL("./daytona-broker-acp.mjs", import.meta.url));
  const child = spawn(process.execPath, [bridge], { stdio: "inherit", env: process.env });
  for (const signal of ["SIGINT", "SIGTERM"]) process.on(signal, () => child.kill(signal));
  child.on("exit", (code, signal) => process.exit(signal ? 1 : code ?? 1));
} else {
  process.stderr.write(`Unsupported Daytona broker agent command: ${args.join(" ")}\n`);
  process.exitCode = 2;
}

// @effect-diagnostics nodeBuiltinImport:off
import * as NodeFS from "node:fs";
import * as NodeOS from "node:os";
import * as NodePath from "node:path";
import * as NodeURL from "node:url";

import * as NodeServices from "@effect/platform-node/NodeServices";
import { it } from "@effect/vitest";
import * as Deferred from "effect/Deferred";
import * as Effect from "effect/Effect";
import * as Stream from "effect/Stream";
import { expect } from "vite-plus/test";

import * as AcpSessionRuntime from "./AcpSessionRuntime.ts";

const bridge = NodePath.resolve(
  NodePath.dirname(NodeURL.fileURLToPath(import.meta.url)),
  "../../../scripts/daytona-broker-acp.mjs",
);

it.effect("T3 ACP runtime receives a Daytona broker worker answer", () =>
  Effect.gen(function* () {
    const root = NodeFS.mkdtempSync(NodePath.join(NodeOS.tmpdir(), "t3-broker-acp-"));
    try {
      NodeFS.mkdirSync(NodePath.join(root, "bin"));
      NodeFS.writeFileSync(
        NodePath.join(root, "bin/run.js"),
        `const action = process.argv[3];
if (action === "start") console.log(JSON.stringify({ id: "11111111-1111-4111-8111-111111111111", status: "starting" }));
else if (action === "wait") console.log(JSON.stringify({ timedOut: false, task: { status: "completed" }, finalMessage: "DAYTONA_NATIVE_TURN_OK" }));
else throw new Error("Unexpected broker action " + action);
`,
      );
      const runtime = yield* AcpSessionRuntime.make({
        spawn: {
          command: process.execPath,
          args: [bridge],
          env: {
            PLANA_BROKER_BUN: process.execPath,
            PLANA_BROKER_ROOT: root,
            PLANA_BROKER_ACP_STATE: NodePath.join(root, "sessions.json"),
          },
        },
        cwd: root,
        clientInfo: { name: "t3-broker-test", version: "0.0.0" },
        authMethodId: "none",
      });
      const updates: Array<AcpSessionRuntime.AcpSessionRuntimeEvent> = [];
      yield* runtime.getEvents().pipe(
        Stream.runForEach((event) => {
          if (event._tag === "EventStreamBarrier") return Deferred.succeed(event.acknowledge, undefined);
          updates.push(event);
          return Effect.void;
        }),
        Effect.forkChild,
      );
      yield* runtime.start();
      expect(yield* runtime.prompt({ prompt: [{ type: "text", text: "Do the task" }] })).toEqual({
        stopReason: "end_turn",
      });
      yield* runtime.drainEvents;
      expect(updates.some((event) => JSON.stringify(event).includes("DAYTONA_NATIVE_TURN_OK"))).toBe(
        true,
      );
    } finally {
      NodeFS.rmSync(root, { recursive: true, force: true });
    }
  }).pipe(Effect.scoped, Effect.provide(NodeServices.layer)),
);

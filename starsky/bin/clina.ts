#!/usr/bin/env tsx
import {
  runClinaAgent,
  type ClinaRequestPayload,
  getProviders,
  CLINA_MCP_TOOLS,
} from "../src/lib/server/clina";

async function main() {
  const rawArg = process.argv[2] || "{}";
  if (rawArg === "--status") {
    process.stdout.write(
      JSON.stringify({
        ok: true,
        engine: "clina-typescript-ide",
        providers: getProviders(),
        mcpTools: CLINA_MCP_TOOLS,
      }) + "\n"
    );
    return;
  }

  let payload: ClinaRequestPayload;
  try {
    payload = JSON.parse(rawArg) as ClinaRequestPayload;
  } catch {
    payload = { prompt: rawArg, mode: "agent" };
  }

  const result = await runClinaAgent(payload);
  process.stdout.write(JSON.stringify(result) + "\n");
}

main().catch((err) => {
  process.stdout.write(
    JSON.stringify({
      ok: false,
      error: err instanceof Error ? err.message : String(err),
    }) + "\n"
  );
  process.exit(1);
});

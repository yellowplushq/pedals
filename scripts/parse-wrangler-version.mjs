import { pathToFileURL } from "node:url";

const VERSION_ID_SOURCE =
  "[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}";
const ANSI_ESCAPE = /\x1b\[[0-?]*[ -/]*[@-~]/g;

export function isWorkerVersionId(value) {
  return new RegExp(`^${VERSION_ID_SOURCE}$`, "i").test(value ?? "");
}

export function extractCurrentVersionId(output) {
  if (typeof output !== "string") return null;
  const normalized = output.replace(ANSI_ESCAPE, "");
  const matches = [
    ...normalized.matchAll(
      new RegExp(`Current Version ID:\\s*(${VERSION_ID_SOURCE})`, "gi"),
    ),
  ];
  return matches.length === 0 ? null : matches.at(-1)[1].toLowerCase();
}

async function main() {
  let output = "";
  process.stdin.setEncoding("utf8");
  for await (const chunk of process.stdin) output += chunk;
  const versionId = extractCurrentVersionId(output);
  if (!versionId) {
    console.error("could not find a full Current Version ID in Wrangler deploy output");
    process.exitCode = 1;
    return;
  }
  process.stdout.write(`${versionId}\n`);
}

if (process.argv[1] && import.meta.url === pathToFileURL(process.argv[1]).href) {
  await main();
}

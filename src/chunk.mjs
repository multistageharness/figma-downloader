// chunk.mjs — the DISK half of the chunked download.
//
// The fetch-and-plan half (frontier walk, batching, bounded concurrency,
// byte/time-aware re-chunking) lives in `@internal/figma-api-fetch-file`'s
// driver; this module supplies the sink callback that lands each completed
// part on disk and maintains the manifest. Part-file bytes and names anchor
// the cross-language parity contract with the Python twin, so the driver hands
// back the exact canonical serialization (`json`) and content-hashed filename
// this module has always written — this file writes those bytes verbatim.
//
// Two scaling mechanisms survive unchanged in behaviour:
//   • Content-hash part files (TR-12): a part is named by the sha256 of its
//     sorted id-batch, so an unchanged batch yields the same filename and a
//     resume reuses it. The manifest records, per planned group, which part
//     files it produced — so resume is correct even when a group was re-chunked.
//   • Byte/time-aware re-chunking (TR-3): over-budget batches are split by the
//     driver into a SHALLOW parent part plus a full part per child, recursively.

import { createWriteStream, promises as fs } from "node:fs";
import path from "node:path";
import { downloadChunks as driveChunks } from "@internal/figma-api-fetch-file";

// The frontier walk moved into the package; re-exported so the CLI and tests
// keep one import site for it.
export { collectFrontierIds } from "@internal/figma-api-fetch-file";

async function exists(p) {
  try {
    await fs.access(p);
    return true;
  } catch {
    return false;
  }
}

/** Write a JSON string to disk — buffered, or streamed with backpressure. */
async function writeJson(partPath, json, stream) {
  if (!stream) {
    await fs.writeFile(partPath, json, "utf8");
    return;
  }
  await new Promise((resolve, reject) => {
    const ws = createWriteStream(partPath, { encoding: "utf8" });
    ws.on("error", reject);
    ws.on("finish", resolve);
    const CH = 1 << 16;
    let i = 0;
    (function pump() {
      let ok = true;
      while (i < json.length && ok) {
        const slice = json.slice(i, i + CH);
        i += CH;
        if (i >= json.length) {
          ws.end(slice);
          return;
        }
        ok = ws.write(slice);
      }
      if (i < json.length && !ok) ws.once("drain", pump);
    })();
  });
}

/**
 * Stream-download the full subtree for every frontier id into content-hashed
 * part files under `<workDir>/parts/`, re-chunking any over-budget subtree, and
 * write a complete `manifest.json` in a single pass. The package driver decides
 * WHAT to fetch and HOW to re-chunk; this function decides how bytes land.
 *
 * @param {object} opts  as before, except `client` (a FigmaFileClient)
 *                       replaces `token`/`retries` — retry, timeout and
 *                       transport now live on the client.
 * @returns {Promise<{ manifest: object, partFiles: string[] }>}
 */
export async function downloadChunks({
  client,
  fileKey,
  frontierIds,
  depth,
  workDir,
  size,
  batchSize = 10,
  concurrency = 4,
  resume = false,
  timeoutMs,
  geometry = false,
  version,
  nodeDepth,
  stream = false,
  rechunk = false,
  maxPartBytes = 0,
  maxPartMs = 0,
  maxRechunkDepth = 4,
  limiter = null,
  log = () => {},
}) {
  const partsDir = path.join(workDir, "parts");
  await fs.mkdir(partsDir, { recursive: true });

  // Prior manifest enables correct resume even for re-chunked groups.
  const priorGroups = new Map();
  if (resume) {
    try {
      const prior = JSON.parse(
        await fs.readFile(path.join(workDir, "manifest.json"), "utf8"),
      );
      for (const g of prior.groups || []) priorGroups.set(g.sha, g);
    } catch {
      /* no prior manifest — nothing to resume */
    }
  }

  // Resume seam: reuse a prior group's parts when every file is present.
  const resumeGroup = resume
    ? async ({ groupSha }) => {
        const g = priorGroups.get(groupSha);
        if (!g) return null;
        const parts = g.parts || [];
        const present =
          parts.length &&
          (
            await Promise.all(parts.map((f) => exists(path.join(partsDir, f))))
          ).every(Boolean);
        if (!present) return null;
        const out = [];
        for (const f of parts) {
          const st = await fs.stat(path.join(partsDir, f));
          out.push({ file: f, ids: g.ids, bytes: st.size });
        }
        return { parts: out, rechunked: !!g.rechunked };
      }
    : undefined;

  const result = await driveChunks({
    client,
    fileKey,
    frontierIds,
    depth,
    batchSize,
    concurrency,
    geometry,
    version,
    nodeDepth,
    timeoutMs,
    rechunk,
    maxPartBytes,
    maxPartMs,
    maxRechunkDepth,
    limiter,
    resumeGroup,
    log,
    // The sink: land the driver's canonical bytes, verbatim.
    sink: async ({ file, json }) => {
      await writeJson(path.join(partsDir, file), json, stream);
    },
  });

  const partFiles = result.parts.map((p) => path.join(partsDir, p.file));

  const manifest = {
    fileKey,
    size: size ?? null,
    frontierDepth: result.frontierDepth,
    batchSize: result.batchSize,
    concurrency: result.concurrency,
    idCount: result.idCount,
    batchCount: result.batchCount,
    downloaded: result.downloaded,
    resumedSkipped: result.resumedSkipped,
    rechunked: result.rechunked,
    oversizedLeaves: result.oversizedLeaves,
    frontierIds: result.frontierIds,
    parts: result.parts,
    groups: result.groups,
  };
  await fs.writeFile(
    path.join(workDir, "manifest.json"),
    JSON.stringify(manifest, null, 2),
    "utf8",
  );
  return { manifest, partFiles };
}

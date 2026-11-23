// mock.mjs — load the offline fixture document for `--mock` runs and tests.
//
// The canonical document lives in the language-neutral shared fixture
// (`packages/shared/fixtures/mock-file.json`) so the Node and Python twins
// serve byte-identical data — the bedrock of the cross-language parity harness.
//
// The endpoint-faking half that used to live here (`makeMockFetch`) was
// replaced by `@internal/figma-api-fetch-file`'s `FixtureFetchAdapter`, which
// serves the same three endpoints (including `?depth=N` truncation) through
// per-client adapter injection instead of a mutable module-level fetch holder.
// This module keeps only the fixture itself.

import { readFileSync } from "node:fs";
import path from "node:path";
import { fileURLToPath } from "node:url";

const __dirname = path.dirname(fileURLToPath(import.meta.url));
const FIXTURE = path.resolve(__dirname, "../../shared/fixtures/mock-file.json");

/** A deep document: 1 page → 3 frames → each with nested children. */
export const MOCK_FILE = JSON.parse(readFileSync(FIXTURE, "utf8"));

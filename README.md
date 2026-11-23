# figma-downloader — Node twin (`packages/ts`)

**Node ESM** (Node ≥ 20) downloader for a Figma file of **any size**
(`sm`/`md`/`large`/`xl`/`xxxxl`), built on the workspace SDK. **Output twin** of the
stdlib-only [`py`](../py): the two produce **byte-identical** output (enforced by
[`../parity`](../parity)). They are no longer *implementation* twins — see
[Dependencies](#dependencies) for the deliberate trade.

## Dependencies

This CLI's HTTP stack is the shared workspace SDK:

```
@internal/figma-api-fetch-file  (endpoints + chunk driver + sizing)
  └── @internal/figma-api-fetch (client, retry, adapters)
        └── undici + zod
```

It is declared as a `file:` dependency on
`figma-api/v100/packages/ts/figma-fetch-file` — same repository, no registry, no
publish step; the analogue of how the SDK workspace's own packages link to each other.
The SDK must be **built before** the downloader runs or tests
(`make sdk`, wired into `make test`/`make audit`).

The v300 TS twin was previously zero-dependency (Node built-ins only). That property
was traded **deliberately** (plan decision D3 of the figma-fetch consolidation) for a
single shared HTTP stack across the workspace: one retry/timeout/proxy implementation
instead of two drifting copies. What is *preserved* — and enforced on every parity
run — is byte-identical **output** with the Python twin, which stays stdlib-only.

## Why chunk it

`GET /v1/files/:key` returns the entire document in one response — hundreds of MB for
large files, and the request routinely times out. Instead this tool pages through the
two endpoints Figma offers:

- `GET /v1/files/:key?depth=N` — the document **truncated** at depth `N` (the skeleton).
- `GET /v1/files/:key/nodes?ids=a,b,c` — the **full subtree** for a batch of node ids.

```
            depth=2 skeleton                       reconstructed full.json
        ┌───────────────────────┐                ┌───────────────────────┐
DOCUMENT│ 0:0                    │                │ 0:0                    │
 └ CANVAS│ 0:1                   │   graft        │ 0:1                    │
    ├ FRAME 1:100  (truncated) ──┼── parts ──────▶│  ├ FRAME 1:100 …deep   │
    ├ FRAME 1:200  (truncated) ──┤                │  ├ FRAME 1:200 …deep   │
    └ FRAME 1:300  (truncated) ──┘                │  └ FRAME 1:300 …deep   │
        └───────────────────────┘                └───────────────────────┘
        1 small request          /nodes?ids=… in batches → parts/ → merged
```

1. **Skeleton** — one shallow `?depth=N` fetch. Its nodes at depth `N` (the *frontier*)
   had their children omitted.
2. **Chunks** — re-fetch every frontier node's full subtree via `/nodes`, a **batch**
   of ids per request, bounded **concurrency**, each response written to a
   content-hashed `parts/part-<sha>.json`. Any over-budget subtree is **re-chunked**.
3. **Reconstruct** — graft the subtrees back onto the skeleton → a single `full.json`
   shaped exactly like a plain `GET /v1/files/:key`.

## Usage

```bash
# Offline smoke test (no token, no network):
node bin/figma-download.mjs --mock --pretty --stdout

# Live, any size — auto-classify and resume on interrupt:
FIGMA_TOKEN=figd_xxx node bin/figma-download.mjs \
  --url https://www.figma.com/design/<KEY>/Name --resume

# Force a tier for a known-huge file:
FIGMA_TOKEN=figd_xxx node bin/figma-download.mjs --file-key <KEY> --size xxxxl

# Rebuild from an already-downloaded work dir (no network):
node bin/figma-download.mjs --reconstruct-only --work-dir out/<KEY>
```

Run `node bin/figma-download.mjs --help` for the full flag list.

## Size: any file (`sm` … `xxxxl`)

`--size {auto|sm|md|large|xl|xxxxl}` (default `auto`). `auto` probes the skeleton and
picks a strategy; a tier sets depth/batch-size/concurrency unless you pass those flags
explicitly (**explicit > tier > auto**). See the [polyglot README](../README.md#the-any-size-model)
for the tier table.

**Byte/time-aware re-chunking** is the guarantee that makes any size work: a fetched
batch over `--max-part-bytes` or `--max-part-ms` is split in memory into a shallow
parent part plus a full part per child, recursively (bounded by `--max-rechunk-depth`,
default 4). A single unsplittable oversized leaf is kept and flagged
`oversizedLeaves` in the manifest. *(A node with enormous fan-out at one level yields a
large shallow parent part — re-chunk shrinks max part size dramatically but does not
paginate one node's direct-children list; that residual case is reported, never lost.)*

## Network: proxy & TLS (flag · config · env)

Defaults: **no proxy**, **TLS verification on**. Override via any of (highest wins):

1. CLI: `--proxy <url>` / `--no-proxy` ; `--ssl-verify` / `--no-ssl-verify` (alias `--insecure`)
2. Config file `./figma-download.config.json` (or `--config <path>`):
   `{ "proxy": "http://host:8080", "sslVerify": false }`
3. Env: `FIGMA_PROXY_URL` / `FIGMA_PROXY` / `HTTPS_PROXY` / `HTTP_PROXY` / `ALL_PROXY` ; `FIGMA_SSL_VERIFY` / `NODE_TLS_REJECT_UNAUTHORIZED`
4. Default: `proxy=null`, `sslVerify=true`

Per-request timeout (default `60000`ms) resolves `--timeout-ms <n>` flag > `FIGMA_HTTP_TIMEOUT_MS` env > default.

The proxy/TLS transport is the SDK's `ProxyTlsFetchAdapter` — a layer over
`node:http`/`https`/`tls` (CONNECT tunnel for HTTPS, credential redaction in logs) —
injected only when a proxy or `--no-ssl-verify` is in effect. `--mock` is offline and
ignores both.

## Errors & exit codes

The SDK's typed errors are translated to this CLI's documented exit codes at the CLI
boundary (`errors.mjs`): 401/403 → exit **3**, 404 → **4**, 429 → **5**,
server/network → **6**, timeout → **7**, bad input → **2**. Auth/not-found fail fast;
429/5xx/network/timeout retry with exponential backoff honoring `Retry-After`. (The
SDK's own `exitCode` table is finer-grained and deliberately different; this CLI's
contract is pinned by the Python twin.)

## Output encoding

Every JSON written escapes U+2028 / U+2029 (which Figma text nodes contain and
`JSON.stringify` emits literally) to ``\u2028`` / ``\u2029`` — semantically identical, but
valid everywhere. Compact `full.json` is byte-identical to the Python twin's.

## Work-dir layout

```
out/<fileKey>/
├── skeleton.json            # the shallow ?depth=N document
├── parts/part-<sha>.json    # /nodes responses, content-hash addressed (TR-12)
├── manifest.json            # size, frontierDepth, parts[], groups[], rechunked, oversizedLeaves
└── full.json                # the reconstructed single file
```

## Develop

```bash
make sdk         # build the workspace SDK packages this CLI depends on
make test        # builds the SDK, then node --test (no network — shared mock fixture)
make typecheck   # node --check every source file
make mock        # chunked download of the shared fixture -> stdout
```

## Layout

```
ts/
├── bin/figma-download.mjs   # CLI entrypoint
├── src/
│   ├── cli.mjs              # arg parse + orchestration (client built from config)
│   ├── config.mjs           # proxy/TLS resolution (flag > config > env > default)
│   ├── errors.mjs           # CLI exit-code taxonomy + SDK-error translation
│   ├── chunk.mjs            # disk half: sink for the SDK driver, parts + manifest
│   ├── reconstruct.mjs      # recursive id-keyed graft -> full file
│   ├── mock.mjs             # loads the shared offline fixture document
│   └── util.mjs             # stringify / token-bucket / count / byte-length
└── tests/                   # download · sizing · rechunk · errors · config (all offline)

Fetching, retry, batching, re-chunking and sizing live in
`@internal/figma-api-fetch-file`; `--mock` runs through its injected
`FixtureFetchAdapter`.
```

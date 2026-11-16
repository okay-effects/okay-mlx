# The desktop panel: models managed, clients kept in step

The macOS app in `desktop/` (SwiftUI, `desktop/build.sh`) is how the owner of the Mac runs okay-mlx: the service,
the models, the clients. This spec says what "managing models" means here, what is built, and what comes next.

## 1. What managing models means

1. **See** what is on disk and what is in memory: each model's size, kind (dense / mixture of experts),
   quantization, context, and whether it fits the memory free now.
2. **Hold memory on purpose**: load a model now, unload it, unload by itself when idle (a 35B holds ~20 GB).
3. **Settle a model without files**: sampling, hot experts, guesses, drafts (`models.json`), the startup model (the
   LaunchAgent's `MLX_MODEL`).
4. **Keep the library**: find and download models, delete them, hide research builds from clients.
5. **Clients follow by themselves**: OpenChamber/opencode list exactly the models there are, with their context.
6. **Watch the work**: which client asks now, how far a generation is, how fast.

## 2. Built (2026-11-14)

- Server (`app/…/Admin.scala`, `Switching.scala`, `Settings.scala`): `GET /admin/status`, `POST /admin/load
  {"model","reload"}`, `POST /admin/unload {"force"}`; no model in memory until asked; `"hidden"` by model,
  `local/…` hidden unless `"hidden": false`; `"*": {"unload_after_minutes"}`.
- App: Overview (the model in memory, unload, unload when idle), Models (load/unload, settings sheet, startup,
  hide, delete, fit badge), Clients (OpenChamber status/open/restart, opencode provider synced in
  `~/.config/opencode/opencode.jsonc` — JSONC edited in place, only the `okay-mlx` block, backup `.okay-mlx.bak`;
  connection lines). en/ru/uk. Weight files validated through their HF symlinks.

## 3. Next (in order; SPRINT.md holds the steps and outcomes)

Status 2026-11-14: 3.1, 3.3–3.6 built and checked; 3.2 built, waiting for the owner to see the menu bar item.

### 3.1 Find models on Hugging Face
A search box over `https://huggingface.co/api/models` (author `mlx-community` by default, any author allowed),
asking `expand[]=config&expand[]=safetensors&expand[]=downloads&expand[]=lastModified`: `config.model_type`
filters to the architectures okay-mlx runs (`qwen3`, `qwen3_5`, `qwen3_5_moe`); `safetensors.parameters` (count by
dtype) gives the bytes (BF16/F16 ×2, U32/F32/I32 ×4, U8/I8 ×1), so each result says its size and whether it fits
this Mac (`Library.fit` on the physical memory and the server's room). A result already downloaded says so;
Download starts the existing downloader. Rejected: scraping the HF web search (unstable HTML); fetching each
result's config.json (N requests a search).

### 3.2 A menu bar item
`MenuBarExtra` (SwiftUI, macOS 13+) beside the window: the state dot, the model in memory, the downloaded models
(not hidden) to switch to, Unload, Open panel, Open OpenChamber. The panel's models move to the app level so both
scenes share them; closing the window leaves the menu (the app keeps running).

### 3.3 The work going on
`/admin/status` gains `generations`: per running generation its model, client (the request's `User-Agent`,
shortened), prompt tokens, tokens so far, seconds, tokens a second. The client is set by `Main` for the thread
serving the request (a `ThreadLocal`, read by `Switching.start`: the gateway runs a request on the thread that
accepted it). The Overview lists them live (refresh 2 s while any runs).

### 3.4 OpenChamber, closer
- **New models without a restart**: find what OpenChamber/opencode 2 offer to re-read config (an instance
  dispose / config reload route); else keep the restart button and say so.
- **Its default model**: choose which okay-mlx model opencode starts with (top-level `"model":
  "okay-mlx/<id>"` in opencode.jsonc, or OpenChamber's own setting if it has one).
- **iPhone pairing**: run `openchamber connect-url --relay --qr`-equivalent from the panel and show the URL as a QR
  code (Core Image `CIQRCodeGenerator`), single-use, with its expiry.

### 3.5 OpenChamber's LaunchAgent cleaned
Its plist carries a copied agent environment (`CLAUDECODE=1`, `CLAUDE_CODE_*`, `AI_AGENT`, terminal variables).
Keep only what a service needs (PATH, HOME, LANG, …); back up the plist; restart once.

### 3.6 Release, the same version
Per the owner's rule (one version while unused): rebuild the server archive (`scripts/package-server.sh`) and the
app zip (`desktop/package.sh`), upload over the v0.1.1 assets, move the tag to the commit; `install.sh` and the
README's link then give the new server and app.

## 4. Batched decode across requests (2026-11-15, the operator: "делай батчинг")

**Why.** One request decodes at mlx_lm's speed (35B-A3B 105 vs 109 tok/s), but requests take turns on the one MLX
thread a token at a time: N agents share one stream. Decode is bound by reading the weights; one step for B
sequences reads them once.

**The design (mlx-scala + okay-mlx):**
- `Model.stepMany(ids [1, B], states)` → logits [1, B, V]: one token for each of B sequences. Default: each row by
  `logits` (correct for any model). Qwen35 and Qwen3 override: embedding, norms, every projection, the MLP and the
  experts on the B rows at once (the B tokens are a "sequence" to them); per row only what is the row's own — RoPE
  at its offset, its KV cache, its attention; the linear layers' conv and delta rule from its own state (n = 1).
  Numerically close to the rows apart, not bit-exact (a matmul over B rows is another kernel than over one).
- `Batch` (mlx-scala): the sessions decoding plainly on one model. A ROUND: every member's pending token (a lazy
  array) stacked, `stepMany`, each member's own choice on its row (its sampling, its mask, its penalties), the new
  steps started, then the old tokens read into each member's `ready` queue — the same pipelining as one session.
  A session's `next()` with an empty queue runs a round: one round gives a token to every member.
- A member is a session in PLAIN mode: no port, no guesses, no drafts (they are per-sequence passes). Policy in
  okay-mlx: a request that starts while another generation runs starts plain and joins the batch; one alone keeps
  its drafts and guesses (the single-user speed). A finished or closed session leaves.
- All on the one MLX thread (as now): no locks.

**Measure:** the logits of `stepMany` against each row's `logits` (relative error), greedy tokens over 64 steps for
3 prompts batched vs apart; then on the gateway: 1, 2, 4 concurrent requests on the 4B and the 35B — total and
per-request tok/s, before and after (bench/history.tsv).

## 5. Hot experts in place; the history of resources (2026-11-16)

- **Hot experts changed in place** (the operator: no reload when memory changes): mlx-scala's `Model.reslot(n)`
  makes or closes a mixture of experts' hot-expert caches between steps — the weights stay mapped, the prefix cache,
  states and adapter kept. `Switching.fitMemory` puts Qwen3.6-35B on its hot experts under pressure and back on all of
  them when memory is easy for ten minutes, in place (`on N hot experts a layer, in place (0.x s)` in the log); a
  reload only for a model that cannot. Qwen35Suite: whole → 64 → 16 → 64 in one model, mlx_lm's tokens each time.
- **Resources → History** (the operator: a historical chart of the gateway's and the model's use): the hub samples
  every 5 seconds while the app runs, window open or not — the gateway process's CPU and memory footprint (its own,
  without the model's), the model's MLX memory, swap, memory pressure, decode speed, the model and its hot experts —
  into ~/Library/Application Support/okay-mlx/usage.tsv, a day kept. Swift Charts over 15 min / 1 h / 6 h / 24 h
  (bucket averages, a peak for speed), memory-pressure bands, a rule where the model changed (a sample with no answer
  from the gateway is unknown, not "unloaded").

## 6. Idle holds nothing; a long prompt stops no one (2026-11-16, the operator)

- **The heap given back** — Scala Native's GC (Immix) never returns its heap, and keeps it ≥ 4× the live data at its
  peak (`Heap_shouldGrow`): a model's load left 1.1 GB with no model. Halved at the source (mlx-scala
  `Tokenizer.fromFile`: tokenizer.json scanned into its tables, no JSON tree — 546 MB). The rest: after an idle
  unload (`unload_after_minutes`) the service process exits and launchd starts it afresh (~8 MB), with no model
  (`~/.cache/okay-mlx/idle-restart` names the one unloaded: the next request naming none loads it). Only under
  launchd (`XPC_SERVICE_NAME`), or `OKAY_MLX_RECYCLE=1`; `=0` never. Checked: 1111 MB → exit after 90 s with 1 min
  set → restarted at 8.3 MB, no model, the mark consumed.
- **The prompt in chunks** (mlx-scala `Session.prefillStep`): a request's prompt is read one chunk per MLX-thread task
  — 2048 tokens alone, 512 (`OKAY_MLX_SHARED_CHUNK`) while other requests are going — so their tokens come between the
  chunks. Before, a request reading a new 9k-token prompt stopped every other request for its whole prefill (12.5 s on
  Qwen3.5-4B); now the largest gap is ~0.6 s and the new request's first token no later (bench/stall.sh,
  bench/history.tsv). PrefillStepSuite: chunked = whole, greedy-exact; interleaved with another's decode, each its
  own.

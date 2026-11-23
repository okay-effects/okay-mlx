# SPRINT — okay-mlx

- [x] **batch** — batched decode across requests (specs/desktop-panel.md §4). mlx-scala (in a worktree: the main
  checkout has another session's Lora edits): `Model.stepMany`, Qwen35/Qwen3 overrides, `Session` plain-mode hooks,
  `Batch`; a suite (stepMany ≈ logits per row; greedy tokens equal over 64 steps). okay-mlx: `MlxBackend` one Batch
  per model, a request starting while another runs → plain + joins. Done when: 2 and 4 concurrent requests measured
  before/after on 4B and 35B, rows in bench/history.tsv, the service reinstalled.
  OUTCOME 2026-11-15: mlx-scala 0047b40 (stepMany, Batch, BatchSuite: rows within the code's own noise — 0.6B 1.62% vs
  1.49%, 0.8B 0.99 vs 1.21, 35B 2.45 vs 2.76 —, copies identical; 35B three sessions 107 → 171 tok/s, same tokens).
  Gateway (bench/history.tsv): 4B 2 requests 80 → 123, 4 requests 73 → 162 tok/s total; 35B 101 → 117, 100 → 136.
  Before batching, concurrency was WORSE than one request (per-sequence passes interleaved). Found on the way: a
  generation whose client vanished stayed "running" for hours (no unload, no memory fitting) — fixed 93b1b02.
- [x] **batch-2** — the first request (alone: drafts/guesses) turned plain and joined when a second arrives — now 2
  requests give 123 tok/s total against 146 for one; drafting → plain is one-way (the draft layer dropped: y = a step
  over `last`). Measure n=2 again; target ≥ one request's total.
  OUTCOME 2026-11-15 (mlx-scala b610544): every session joins the batch from its start; with two alive, one
  guessing/drafting turns plain. Gateway: 4B 2 requests 191, 4 requests 251 tok/s total (one: 142); 35B 162 / 220 (one:
  145) — against 80/73 and 101/100 before batching. BatchJoinSuite: the turned session's tokens its own (0.6B 80/80;
  35B with drafts 29 then a bf16 near tie), rounds 1.71 wide.

## Done: the desktop panel (specs/desktop-panel.md)

Queue, in order (the owner, 2026-11-14: "делай всё по порядку"). Design: specs/desktop-panel.md §3.
`[~]` in progress, `[x]` done (with the commit and the outcome).

- [x] **hf-search** — find models on Hugging Face in the Models tab (spec §3.1). New `desktop/Catalog.swift`
  (search request, size from `safetensors.parameters`, arch filter), a search field + results list in
  `ModelsView.swift` above "Downloaded models"; Download reuses `InstallModel.model`. Done when: searching "Qwen3.5"
  lists mlx-community models with size, context-free, a fit badge, "downloaded" on the ones there; non-Qwen results
  are left out.
  OUTCOME 2026-11-14: Models tab → "Find on Hugging Face" (Catalog.swift, one request with config+safetensors
  expanded). HF counts quantized U32 two ways by repo (logical weights or packed words); the BF16/U32 ratio picks
  the formula — sizes exact within 0.2% (35B-A3B-4bit 20.39 vs 20.43 GB on disk; 4B both repos 3.03 GB).
- [~] **menu-bar** — `MenuBarExtra` (spec §3.2). Move `PanelModel`/`LibraryModel`/`InstallModel` to the `App`
  struct, pass them in; menu: state, model in memory, switch list, Unload, Open panel, Open OpenChamber. Done when:
  closing the window keeps the menu, switching from the menu loads the model (status shows it).
  BUILT 2026-11-14 (Hub in OkayMLX.swift owns the models, refreshes every 4 s, disk rescan every 30 s; MenuView.swift;
  menu-bar symbol: cpu down / memorychip none / memorychip.fill loaded / cpu.fill generating). NOT SEEN: the screen
  was locked (menu bar captured black; on macOS 26+ status items are drawn by the system, not in the app's window
  list). Owner to check: the icon is there, the window opens from "Panel…", switching loads.
- [x] **live-work** — running generations in `/admin/status` and on the Overview (spec §3.3). Server: `Main` sets a
  `ThreadLocal` client from `User-Agent`; `Switching.Running` keeps client, prompt tokens, tokens, start. App: a
  list under the model in memory. Done when: a curl generation shows up with its client and growing tokens.
  OUTCOME 2026-11-14: /admin/status "generations" [model, client, prompt_tokens (-1 in prefill), cached, tokens,
  millis, per_second]; client = User-Agent's first product (Admin.clientOf). Seen live: opencode 173→363 tokens
  ~117 tok/s; the Overview lists them, the hub polls every 1 s while any runs.
- [x] **chamber-closer** — OpenChamber: reload without restart if it can, default model, iPhone pairing QR (spec
  §3.4). First investigate OpenChamber 2.5.3 / opencode 2.2.5 routes (npm -g @openchamber/web sources).
  OUTCOME 2026-11-14: no restart needed — opencode 2.2.5 watches opencode.jsonc (OpenChamber's GET /api/model
  listed the 9 synced models at once). ChamberAPI (Clients.swift): POST /auth/session {password from
  ~/.config/openchamber/ui-password.txt} → cookie; GET /api/model (okay-mlx models it offers: "offers 9 of 9");
  GET/PUT /api/config/settings {defaultModel: "okay-mlx/<id>"} (picker on the Clients tab); pairing = OpenChamber's
  node + cli.js `connect-url --relay --json --port 3000` → connectUrl/expiresAt/fingerprint → QR (CIQRCodeGenerator,
  320 pt + white border: the link is ~1 kB, a dense code). /api/config/reload exists (restarts managed opencode
  only) — not needed now. Pairing checked by a harness; the QR not yet scanned by the iPhone (owner).
- [x] **chamber-env** — clean OpenChamber's LaunchAgent environment, backup, restart once (spec §3.5).
  OUTCOME 2026-11-14: 31 variables removed from ~/Library/LaunchAgents/dev.openchamber.web.plist (CLAUDECODE,
  CLAUDE_CODE_* incl. a messaging token, ROZUM_MEETING_TOKEN, GIT_EDITOR=true, AI_AGENT, GHOSTTY_*, terminal and
  XPC ones, SSH_AUTH_SOCK); kept PATH, HOME, LANG, JAVA_HOME, SDKMAN_*, HOMEBREW_*, OPENCODE_BINARY,
  OPENCHAMBER_UI_PASSWORD. Backup ~/.config/openchamber/dev.openchamber.web.plist.before-clean-20261114 (outside
  LaunchAgents). bootout+bootstrap once; HTTP 200, the process has none of them, 9 okay-mlx models offered. Cause:
  the service was installed from inside an agent session (its environment copied) — reinstalling it from an agent
  would bring them back.
- [x] **release** — rebuild + re-upload v0.1.1 server archive and app zip, move the tag (spec §3.6).
  OUTCOME 2026-11-14: v0.1.1 assets replaced (server 7d8f6bef…, app e2c8774c…, SHA256SUMS both), tag moved
  3c4bb2a → aeb546e. Gotcha: build with MLX_C_SOURCE=~/work/my/mlx-scala/native-lib/src — the cached CMake build in
  target/macos14 was made from it; the default (a fresh clone in target/macos14/src) fails "source does not match".
- [x] **events** — DONE 2026-11-23: `Events.scala` (Gauge effect, pure `diff`, the stream a program over Gauge + Clock +
  Http; `Mcp` route on `/mcp`); EventsSuite (6, virtual clock, no model); native gateway reinstalled
  (okay-mlx.before-events kept); live: an opencode 2.3 session asleep on `model.loaded` woke the second a model loaded.
  Was: (operator 2026-11-23) — the gateway as an MCP server of the draft extension `io.modelcontextprotocol/
  events` (see rozum SPRINT "MCP Events", its spike first): `/mcp` on the same port with a `status` tool and event
  types `model.loaded`, `model.unloaded`, `memory.room` (arguments `min_gb`: fires when the machine's room for MLX
  reaches it), `gpu.starved` / `gpu.freed` (a generation with no token for 3 min, and its end), `generation.done`;
  poll + push, cursor = an event counter since start (no replay across restarts: `cursor: null` after one). Who
  consumes: opencode sessions (`opencode_watch_mcp_event`: an agent waits for room instead of polling), okay-loop's
  `--wait-room` (now polls /admin/status each minute), the desktop app. Done when: an opencode session wakes on
  `memory.room`, and okay-loop's wait watches the event.

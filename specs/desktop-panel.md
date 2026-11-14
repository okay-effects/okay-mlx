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

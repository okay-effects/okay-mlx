# okay-mlx — notes for agents

okay-llm's MLX module: `MlxBackend` (an `Llm.Backend` on mlx-scala's `Model`, `Chat`, `Session`; okay-llm's JSON
converted to mlx-scala's), and `Main` (ask, bench, serve). One crossProject `app/`, package `okay.mlx`.

- Depends on mlx-scala and okay-llm `0.1.0-SNAPSHOT` by `publishLocal`, and on mlx-scala's native libraries:
  `MLX_SCALA_LIB`, else `../mlx-scala/native-lib/out/lib`. Native builds embed resources (mlx-scala's NFC data).
- `MlxBackend.open` loads the model ON the backend's MLX thread (`OnThread`): every MLX call there, whichever HTTP
  thread asks. Sampling: the request's, else `Sampling.of(dir)`. Once, at temperature 1 (Qwen3.6's own), Claude Code
  looped ~400 turns on a two-step task; four reruns did not — no presence_penalty yet.
- Drafts: the model's own (mlx-scala MTP, when its pack is there: `mtpFetch`), `Settings.drafts` (OKAY_MLX_DRAFTS,
  default 2; 0: guesses from the text instead), off on hot experts. The cache also keeps the state after each answer
  and after `<tool_call>` (`Chat.anchors`).
- Exact quotes (2026-11-07): a request's `okay_quote` (okay-llm `Ask.quote`: markers, sources) → mlx-scala's `Quote`
  port on the `Session` — between ⟦ ⟧ only a span of the sources (each tokenized alone; none given: the prompt).
- `MlxBackend` keeps one `PrefixCache` for all requests; `OKAY_MLX_DUMP=<dir>` writes each rendered prompt (a cache
  miss is where two prompts part — Claude Code's billing header and its mid-conversation system messages were two).
- The effects, the gateway, the server, the programs are okay-llm's; nothing here but the hardware and the wiring.

Build: `sbt test` (the backend on Qwen3-4B, skipped without it), `sbt "appNative/run serve 8090"`. Lines at most 120.

## Managed (2026-11-14)

- `Admin` (same port, /admin/…): `GET /admin/status` (the model loaded or none, loading, running, MLX memory, the
  machine's room and pressure, the last generation's speeds), `POST /admin/load {"model", "reload"}`,
  `POST /admin/unload {"force"}`. `Switching` can hold no model (the next request loads the one it names, else the
  last); a startup model that does not load leaves the gateway up. `Settings`: `"hidden": true` by model (not in
  /v1/models), `"*": {"unload_after_minutes": N}` (OKAY_MLX_UNLOAD_AFTER) — unloaded by itself when idle.
- The desktop app (`desktop/`, SwiftUI, `desktop/build.sh`) manages models over these and the files: the HF cache,
  `~/.config/okay-mlx/models.json`, the LaunchAgent's MLX_MODEL, and opencode's provider (OpenChamber).

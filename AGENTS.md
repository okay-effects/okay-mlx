# okay-mlx — notes for agents

okay-llm's MLX module: `MlxBackend` (an `Llm.Backend` on mlx-scala's `Model`, `Chat`, `Session`; okay-llm's JSON
converted to mlx-scala's), and `Main` (ask, bench, serve). One crossProject `app/`, package `okay.mlx`.

- Depends on mlx-scala and okay-llm `0.1.0-SNAPSHOT` by `publishLocal`, and on mlx-scala's native libraries:
  `MLX_SCALA_LIB`, else `../mlx-scala/native-lib/out/lib`. Native builds embed resources (mlx-scala's NFC data).
- `MlxBackend.open` loads the model ON the backend's MLX thread (`OnThread`): every MLX call there, whichever HTTP
  thread asks. Sampling: the request's, else `Sampling.of(dir)`. Once, at temperature 1 (Qwen3.6's own), Claude Code
  looped ~400 turns on a two-step task; four reruns did not — no presence_penalty yet.
- `MlxBackend` keeps one `PrefixCache` for all requests; `OKAY_MLX_DUMP=<dir>` writes each rendered prompt (a cache
  miss is where two prompts part — Claude Code's billing header and its mid-conversation system messages were two).
- The effects, the gateway, the server, the programs are okay-llm's; nothing here but the hardware and the wiring.

Build: `sbt test` (the backend on Qwen3-4B, skipped without it), `sbt "appNative/run serve 8090"`. Lines at most 120.

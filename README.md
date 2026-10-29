# okay-mlx

[okay-llm](https://github.com/okay-effects/okay-llm)'s model on Apple's MLX: [mlx-scala](https://github.com/sergey-scherbina/mlx-scala)
as an `Llm.Backend` — the conversation through the model's own chat template, sampled as the request asks (greedy by
default), its prefix cached in memory and on disk — and the app on it: a question,
a benchmark, the gateway (OpenAI's and Anthropic's APIs). The JVM (FFM) and Scala Native.

```
curl -LO https://github.com/sergey-scherbina/mlx-scala/releases/download/v0.1.0/mlx-scala-native-0.1.0-macos-arm64.tar.gz
mkdir -p mlx-lib && tar xzf mlx-scala-native-0.1.0-macos-arm64.tar.gz -C mlx-lib   # or ../mlx-scala/native-lib/build.sh
export MLX_SCALA_LIB=$PWD/mlx-lib                                                  # the directory with libokm.dylib
sbt "appJVM/run ask What is a KV cache?"
MLX_MODEL=mlx-community/Qwen3.6-35B-A3B-4bit sbt "appNative/run serve 8090"
ANTHROPIC_BASE_URL=http://127.0.0.1:8090 ANTHROPIC_API_KEY=local claude -p "Create hello.txt with the word okay"
```

The model: `MLX_MODEL`, a HuggingFace repository in the cache — Qwen3 (`mlx-community/Qwen3-4B-4bit`, the default),
Qwen3.5, Qwen3.6 (`mlx-community/Qwen3.6-35B-A3B-4bit`).

```scala
val backend = MlxBackend.open(repo, dir)   // the model on a thread of its own
Server.run(8090)((req, out) => run(Log.to(stderr, Level.Info)(Fresh.from(0)(Clock.system(Http.socket(out)(
  Llm.on(backend)(Gateway.route[Gw](req))))))))
```

## Install (the gateway, native)

```
curl -fsSL https://raw.githubusercontent.com/okay-effects/okay-mlx/master/install.sh | sh
okay-mlx service install mlx-community/Qwen3.6-35B-A3B-4bit    # serves 127.0.0.1:8090 now and with every login
```

The release's Scala Native binary and MLX's libraries in ~/.okay-mlx (the binary finds them in ../lib), the command
`okay-mlx` in ~/.local/bin: `ask`, `bench`, `serve [port]`, `service install [model] [port] | uninstall | status`
(a LaunchAgent; its log ~/.okay-mlx/serve.log). Models from the HuggingFace cache (`hf download …`).

A model's sampling, the owner's: ~/.config/okay-mlx/models.json (or `OKAY_MLX_MODELS`), by model, `"*"` for all —
over the model's generation_config.json, under a request's own fields; read when a model loads:

```json
{"*": {"presence_penalty": 1.5},
 "mlx-community/Qwen3.6-35B-A3B-4bit": {"temperature": 0.6, "top_p": 0.95, "top_k": 20, "presence_penalty": 0}}
```

## Get it

```scala
resolvers ++= Seq("okay-mlx" at "https://okay-effects.github.io/okay-mlx/maven",
  "mlx-scala" at "https://sergey-scherbina.github.io/mlx-scala/maven",
  "okay-llm" at "https://okay-effects.github.io/okay-llm/maven",
  "okay-scala" at "https://okay-effects.github.io/okay-scala/maven",
  "okay-simple" at "https://okay-effects.github.io/okay-simple/maven")
libraryDependencies += "io.github.okay-effects" %%% "okay-mlx" % "0.1.0"
```

The native libraries as mlx-scala's [release](https://github.com/sergey-scherbina/mlx-scala/releases/tag/v0.1.0) has
them, `MLX_SCALA_LIB` their directory.

## Measured

Qwen3.6-35B-A3B (4-bit), greedy, 256 tokens out, the median of 3 runs, tokens a second (prefill / decode), M4 Max,
2026-10-29 (mlx-scala 11f1b0f: mlx_lm's packed delta-rule kernel):

| prompt | JVM | Scala Native |
|---|---|---|
| 145 tokens | 946 / 100 | 966 / 98 |
| 5k | 1449 / 96 | 1511 / 94 |
| 9.9k | 1299 / 87 | 1246 / 89 |

For scale, the same model on the same machine (2026-10-28, through their HTTP APIs, a ~10k-token prompt): rozum
1171–1193 / 92, LM Studio 1259–1268 / 101.

The gateway's model is `MLX_MODEL`'s at first; a request naming another (its `model`: a repository in the cache
that loads, `/v1/models` lists them, the one loaded first) loads that one in its place — one in memory at a time,
the old one freed first (19.5 GB back after Qwen3.6-35B), a switch waiting for the old model's generations to end
(one not asked for a token in a minute, its client gone, closed). Any other name — Claude Code's `claude-…`,
rozum's `claude-rozum-…` for its small requests — is answered by the one loaded, so never switches it.

Requests are served at once: every MLX call runs on one thread of the backend's own, the generations taking turns a
token at a time — a short request does not wait for a long one. Tokens drawn as a request says (`temperature`,
`top_p`, `top_k`, `seed`, `presence_penalty`, `frequency_penalty`), else as the model's generation_config.json
does; penalties for clients that send none (Anthropic's API has none: Claude Code) by `OKAY_MLX_PRESENCE_PENALTY`,
`OKAY_MLX_FREQUENCY_PENALTY` — against a sampled loop (Qwen's card: presence 1.5 for general tasks, 0 for code). A prompt's first mark is kept on disk
too (`OKAY_MLX_PREFIXES`, `off` for memory alone; ~/.cache/okay-mlx/prefixes): after a restart Claude Code's first
request took 9k of its 13.5k tokens from there, prefill 6 s instead of 20; the task 13 s.

Prompts' prefixes are kept across requests (mlx-scala's `PrefixCache`): an agent's next turn computes only what is
new. Claude Code, Qwen3.6-35B-A3B, a task of three turns: the first 13.5k tokens' prefill 16.3 s; the next two
13.7k each, 13.5k of them cached — 0.27 s and 0.21 s; the task 26 s instead of 50–57. `OKAY_MLX_DUMP=<dir>` writes
each rendered prompt there: where two turns' prompts part is where a cache misses.

Claude Code ran against the gateway on Scala Native with it: a 13.6k-token prompt with its tools; the model called
`Write` and made the file.

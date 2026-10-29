# okay-mlx

[okay-llm](https://github.com/okay-effects/okay-llm)'s model on Apple's MLX: [mlx-scala](https://github.com/sergey-scherbina/mlx-scala)
as an `Llm.Backend` — the conversation through the model's own chat template, greedy — and the app on it: a question,
a benchmark, the gateway (OpenAI's and Anthropic's APIs). The JVM (FFM) and Scala Native.

```
../mlx-scala/native-lib/build.sh && (cd ../mlx-scala && sbt publishLocal) && (cd ../okay-llm && sbt publishLocal)
sbt "appJVM/run ask What is a KV cache?"
MLX_MODEL=mlx-community/Qwen3.6-35B-A3B-4bit sbt "appNative/run serve 8090"
ANTHROPIC_BASE_URL=http://127.0.0.1:8090 ANTHROPIC_API_KEY=local claude -p "Create hello.txt with the word okay"
```

The model: `MLX_MODEL`, a HuggingFace repository in the cache — Qwen3 (`mlx-community/Qwen3-4B-4bit`, the default),
Qwen3.5, Qwen3.6 (`mlx-community/Qwen3.6-35B-A3B-4bit`).

```scala
val backend = MlxBackend(repo, Model.load(dir), Chat.load(dir))
Server.run(8090)((req, out) => run(Log.to(stderr)(Fresh.from(0)(Clock.system(Http.socket(out)(
  Llm.on(backend)(Gateway.route[Gw](req))))))))
```

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

Prompts' prefixes are kept across requests (mlx-scala's `PrefixCache`): an agent's next turn computes only what is
new. Claude Code, Qwen3.6-35B-A3B, a task of three turns: the first 13.5k tokens' prefill 16.3 s; the next two
13.7k each, 13.5k of them cached — 0.27 s and 0.21 s; the task 26 s instead of 50–57. `OKAY_MLX_DUMP=<dir>` writes
each rendered prompt there: where two turns' prompts part is where a cache misses.

Claude Code ran against the gateway on Scala Native with it: a 13.6k-token prompt with its tools; the model called
`Write` and made the file.

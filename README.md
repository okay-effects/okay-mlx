# okay-mlx

Language models on Apple's MLX ([mlx-scala](https://github.com/sergey-scherbina/mlx-scala)) with
[okay-scala](https://github.com/okay-effects/okay-scala)'s effects, on the JVM and Scala Native: a gateway speaking
OpenAI's and Anthropic's APIs, a question asked, a benchmark. The world is reached through effects — the model,
the response, files, the console, the clock, the log — and handlers give them their meaning: the real ones, and
ones that make every program testable without a GPU, a model, a socket or a disk.

```
../mlx-scala/native-lib/build.sh && (cd ../mlx-scala && sbt publishLocal)    # mlx-scala, once
sbt "appJVM/run serve 8090"                       # the gateway, on the JVM
sbt "appNative/run ask What is a KV cache?"       # a question, on Scala Native
ANTHROPIC_BASE_URL=http://127.0.0.1:8090 ANTHROPIC_API_KEY=local claude -p "What is 17*3?"
```

The model: `MLX_MODEL` (a HuggingFace repository in the cache), `mlx-community/Qwen3-4B-4bit` by default.

## Effects

| effect | operations | handlers |
|---|---|---|
| `Llm` | `name`, `count`, `start`, `next` (a piece of text), `finish` (the turn read: thinking, text, tool calls) | `mlx` (a model on MLX, its chat template), `fake` |
| `Http` | `respond`; `open`, `send`, `close` (a stream) | `socket`, `collect` |
| `Files` | `snapshot` (a model in the HuggingFace cache), `read` | `disk` |
| `Console` | `line` | `stdout`, `collect` |
| std `Clock`, `Fresh`, `Log` | | `system` / `virtual`, `from`, `to` / `collect` |

The gateway is programs of them — `Gateway.route(request)`:

| endpoint | |
|---|---|
| `POST /v1/chat/completions` | OpenAI: whole or streamed (server-sent events), tool calls, `reasoning_content`, `stream_options.include_usage` |
| `POST /v1/messages` | Anthropic: whole or streamed — `thinking`, `text`, `tool_use` blocks |
| `POST /v1/messages/count_tokens`, `GET /v1/models`, `GET /health` | |

A turn streams through a `Streamer`: thinking, then text; a tool call held back and given at the end, read from
the model's format (Qwen3's JSON, Qwen3.6's XML). The server (`Server`) is HTTP/1.1 on `java.net.ServerSocket`, the
same on both platforms: a connection a request, one at a time — one model, one GPU.

```scala
def ask[R[_]: Has[Llm] : Has[Console]](question: String, maxTokens: Int): Finished ! R =
  for
    f <- Llm.complete(user(question).copy(maxTokens = maxTokens))
    _ <- Console.line(f.reply.content)
  yield f
```

Checked: Claude Code (`ANTHROPIC_BASE_URL`) runs against it — a 13k-token system prompt with its tools, the
answer right.

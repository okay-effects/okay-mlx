package okay.mlx

import okay.llm.{Ask, Llm, Timing}
import mlx.llm.{Chat, Model, PrefixCache, Session}

/** okay-llm's model on Apple's MLX (mlx-scala): the conversation through the model's own chat template, greedy —
 * a `Llm.Backend`; `Llm.on(MlxBackend(...))` handles the `Llm` effect. Prompts' prefixes are kept (`PrefixCache`):
 * an agent's next turn computes only what is new. The messages pass as they are: okay-llm and
 * mlx-scala share one JSON, okay-simple's okay-effects-json-value */
final class MlxBackend(val name: String, model: Model, chat: Chat, cache: PrefixCache = PrefixCache())
    extends Llm.Backend:
  private var dumped = 0
  private def prompt(ask: Ask): Array[Int] =
    sys.env.get("OKAY_MLX_DUMP").foreach { dir =>
      dumped += 1
      java.nio.file.Files.writeString(java.nio.file.Path.of(dir, s"prompt-$dumped.txt"),
        chat.template(ask.messages, ask.tools, true, Map("enable_thinking" -> ask.thinking)))
    }
    chat.prompt(ask.messages, ask.tools, Map("enable_thinking" -> ask.thinking))

  def count(ask: Ask): Int = prompt(ask).length

  def start(ask: Ask): Llm.Generation = new Llm.Generation:
    private val tokens = prompt(ask)
    // a prompt's prefixes kept across requests: an agent's system prompt, tools and the conversation so far
    private val session = Session(model, tokens, ask.maxTokens, chat.stops, cache, chat.marks(tokens))
    private val stream = chat.tokenizer.Stream()
    private val sb = new StringBuilder
    def next(): Option[String] = session.next().map { t =>
      val piece = stream.push(t)
      sb.append(piece)
      piece
    }
    def text: String = sb.toString
    def timing: Timing =
      val t = session.timing
      Timing(t.promptTokens, t.prefillNanos, t.tokens, t.decodeNanos, t.cachedTokens)
    def byStop: Boolean = session.endedByStop
    def close(): Unit = session.close()

package okay.mlx

import okay.llm.{Ask, Llm, Timing}
import mlx.llm.{Chat, Model, Session}

/** okay-llm's model on Apple's MLX (mlx-scala): the conversation through the model's own chat template, greedy —
 * a `Llm.Backend`; `Llm.on(MlxBackend(...))` handles the `Llm` effect. The messages pass as they are: okay-llm and
 * mlx-scala share one JSON, okay-simple's okay-effects-json-value */
final class MlxBackend(val name: String, model: Model, chat: Chat) extends Llm.Backend:
  private def prompt(ask: Ask): Array[Int] =
    chat.prompt(ask.messages, ask.tools, Map("enable_thinking" -> ask.thinking))

  def count(ask: Ask): Int = prompt(ask).length

  def start(ask: Ask): Llm.Generation = new Llm.Generation:
    private val session = Session(model, prompt(ask), ask.maxTokens, chat.stops)
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
      Timing(t.promptTokens, t.prefillNanos, t.tokens, t.decodeNanos)
    def byStop: Boolean = session.endedByStop
    def close(): Unit = session.close()

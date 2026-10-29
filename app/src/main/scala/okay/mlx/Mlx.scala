package okay.mlx

import scala.collection.immutable.VectorMap
import okay.effects.json.Json
import okay.llm.{Ask, Llm, Timing}
import mlx.llm.{Chat, Model, Session}

/** okay-llm's model on Apple's MLX (mlx-scala): the conversation through the model's own chat template, greedy —
 * a `Llm.Backend`; `Llm.on(MlxBackend(...))` handles the `Llm` effect */
final class MlxBackend(val name: String, model: Model, chat: Chat) extends Llm.Backend:
  private def prompt(ask: Ask): Array[Int] =
    chat.prompt(ask.messages.map(MlxBackend.json), ask.tools.map(MlxBackend.json),
      Map("enable_thinking" -> ask.thinking))

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

object MlxBackend:
  /** okay-llm's JSON (okay-effects-json) as mlx-scala's: the same structure */
  def json(j: Json): mlx.llm.Json = j match
    case Json.Obj(f) => mlx.llm.Json.Obj(VectorMap.from(f.map((k, v) => k -> json(v))))
    case Json.Arr(xs) => mlx.llm.Json.Arr(xs.map(json))
    case Json.Str(s) => mlx.llm.Json.Str(s)
    case Json.Num(n) => mlx.llm.Json.Num(n.toDouble)
    case Json.Bool(b) => mlx.llm.Json.Bool(b)
    case Json.Null => mlx.llm.Json.Null

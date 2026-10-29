package okay.mlx

import java.nio.file.Path
import java.util.concurrent.{Callable, ExecutionException, Executors}
import okay.llm.{Ask, Llm, Timing}
import mlx.llm.{Chat, Model, PrefixCache, PrefixStore, Sampling, Session}

/** okay-llm's model on Apple's MLX (mlx-scala): the conversation through the model's own chat template — a
 * `Llm.Backend`; `Llm.on(backend)` handles the `Llm` effect. The messages pass as they are: okay-llm and mlx-scala
 * share one JSON. Prompts' prefixes are kept (`PrefixCache`): an agent's next turn computes only what is new.
 *
 * Every MLX call on ONE thread of its own — the model loaded there, each step run there — whichever thread asks:
 * requests served at once take turns on it a token at a time. Tokens drawn as a request says, else as the model's
 * generation_config.json does */
final class MlxBackend private (val name: String, model: Model, chat: Chat, defaults: Sampling, cache: PrefixCache,
    mlx: MlxBackend.OnThread) extends Llm.Backend:
  private def prompt(ask: Ask): Array[Int] =
    MlxBackend.dump(chat, ask)
    chat.prompt(ask.messages, ask.tools, Map("enable_thinking" -> ask.thinking))

  private def sampling(ask: Ask): Sampling =
    val s = ask.sampling
    Sampling(s.temperature.getOrElse(defaults.temperature), s.topP.getOrElse(defaults.topP),
      s.topK.getOrElse(defaults.topK), s.seed)

  def count(ask: Ask): Int = mlx(prompt(ask).length)

  def start(ask: Ask): Llm.Generation = mlx(new Llm.Generation:
    private val tokens = prompt(ask)
    // a prompt's prefixes kept across requests: an agent's system prompt, tools and the conversation so far
    private val session = Session(model, tokens, ask.maxTokens, chat.stops, cache, chat.marks(tokens), sampling(ask))
    private val stream = chat.tokenizer.Stream()
    private val sb = new StringBuilder
    def next(): Option[String] = mlx(session.next().map { t =>
      val piece = stream.push(t)
      sb.append(piece)
      piece
    })
    def text: String = sb.toString
    def timing: Timing =
      val t = session.timing
      Timing(t.promptTokens, t.prefillNanos, t.tokens, t.decodeNanos, t.cachedTokens)
    def byStop: Boolean = session.endedByStop
    def close(): Unit = mlx(session.close()))

object MlxBackend:
  /** the model of a directory, loaded on the backend's own MLX thread; its prompts' prefixes kept in memory and on
   * disk — under OKAY_MLX_PREFIXES (`off`: memory alone), else ~/.cache/okay-mlx/prefixes — so a restart does not
   * compute an agent's system prompt again */
  def open(name: String, dir: Path): MlxBackend =
    val mlx = OnThread()
    mlx {
      val model = Model.load(dir)
      val root = sys.env.get("OKAY_MLX_PREFIXES") match
        case Some("off") => None
        case Some(p) => Some(Path.of(p))
        case None => Some(Path.of(sys.props("user.home"), ".cache", "okay-mlx", "prefixes"))
      val store = root.map(r => PrefixStore.forModel(r, dir, model)).orNull
      MlxBackend(name, model, Chat.load(dir), Sampling.of(dir), PrefixCache(store = store), mlx)
    }

  /** a thread all MLX calls run on: `apply(f)` runs `f` there (at once if on it already) and gives its value */
  final class OnThread:
    @volatile private var thread: Thread | Null = null
    private val executor = Executors.newSingleThreadExecutor { r =>
      val t = Thread(r, "mlx")
      t.setDaemon(true)
      thread = t
      t
    }
    def apply[A](f: => A): A =
      if Thread.currentThread() eq thread then f
      else
        try executor.submit((() => f): Callable[A]).get()
        catch case e: ExecutionException => throw e.getCause

  /** OKAY_MLX_DUMP=<dir>: each rendered prompt written there (where two turns' prompts part, a cache misses) */
  private val dumped = java.util.concurrent.atomic.AtomicInteger()
  private def dump(chat: Chat, ask: Ask): Unit = sys.env.get("OKAY_MLX_DUMP").foreach { dir =>
    java.nio.file.Files.writeString(Path.of(dir, s"prompt-${dumped.incrementAndGet()}.txt"),
      chat.template(ask.messages.map(identity), ask.tools, true, Map("enable_thinking" -> ask.thinking)))
  }

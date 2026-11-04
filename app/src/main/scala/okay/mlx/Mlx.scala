package okay.mlx

import java.nio.file.Path
import java.util.concurrent.{Callable, ExecutionException, Executors}
import okay.llm.{Ask, Llm, Timing}
import mlx.llm.{Adaptable, Chat, Lora, Model, PrefixCache, PrefixStore, Sampling, Session}

/** okay-llm's model on Apple's MLX (mlx-scala): the conversation through the model's own chat template — a
 * `Llm.Backend`; `Llm.on(backend)` handles the `Llm` effect. The messages pass as they are: okay-llm and mlx-scala
 * share one JSON. Prompts' prefixes are kept (`PrefixCache`): an agent's next turn computes only what is new.
 *
 * Every MLX call on ONE thread of its own — the model loaded there, each step run there — whichever thread asks:
 * requests served at once take turns on it a token at a time. Tokens drawn as a request says, else as the model's
 * generation_config.json does */
final class MlxBackend private (val name: String, model: Model, chat: Chat, defaults: Sampling, cache: PrefixCache,
    mlx: MlxBackend.OnThread, guesses: Int, drafts: Int, val slots: Int, val mixture: Boolean, val bytes: Long)
    extends Llm.Backend:
  // whether the model drafts its own (it has a draft layer, and drafts are wanted)
  private val drafting = drafts > 0 && { val d = model.newDraft(); if d != null then d.close(); d != null }
  private def prompt(ask: Ask): Array[Int] =
    MlxBackend.dump(chat, ask)
    chat.prompt(ask.messages, ask.tools, MlxBackend.kwargs(ask))

  private def sampling(ask: Ask): Sampling =
    val s = ask.sampling
    Sampling(s.temperature.getOrElse(defaults.temperature), s.topP.getOrElse(defaults.topP),
      s.topK.getOrElse(defaults.topK), s.seed, s.presencePenalty.getOrElse(defaults.presencePenalty),
      s.frequencyPenalty.getOrElse(defaults.frequencyPenalty))

  def count(ask: Ask): Int = mlx(prompt(ask).length)

  // THE ADAPTER ON the model now (`Adapters`), if any; a prefix cache for each (with one on, the model's states are
  // another model's: the base's prefixes do not hold) — the base's on disk too, an adapter's in memory alone
  private var adapterNow: Option[String] = None
  private var adapterScope: _root_.mlx.Scope | Null = null
  private val caches = scala.collection.mutable.Map[Option[String], PrefixCache](None -> cache)
  def adapter: Option[String] = adapterNow

  /** the adapter put on (or, None, taken off): no generation may be running (the caller waits for them) */
  def use(a: Option[String]): Unit = if a != adapterNow then mlx {
    model match
      case m: Adaptable =>
        m.lora = Map.empty
        if adapterScope != null then adapterScope.nn.close()
        adapterScope = a.map(n => Lora.attach(m, Adapters.path(n, name).toString)).orNull
        adapterNow = a
        System.err.println(s"[Info] $name: " + a.fold("no adapter")(n => s"adapter $n on"))
      case _ => System.err.println(s"[Warn] $name takes no adapters: ${a.mkString} not put on")
  }

  /** the model and its prefixes freed, MLX's buffers given back: the memory free for another model */
  def close(): Unit = mlx {
    caches.values.foreach(_.clear())
    if adapterScope != null then adapterScope.nn.close()
    model.close()
    _root_.mlx.Mlx.clearCache()
  }

  def start(ask: Ask): Llm.Generation = mlx(new Llm.Generation:
    private val tokens = prompt(ask)
    private val prefixes = caches.getOrElseUpdate(adapterNow, PrefixCache(cache.budget))
    // a prompt's prefixes kept across requests: an agent's system prompt, tools and the conversation so far
    // kept too: the state after the answer and after a tool call's opener (the next turn begins there); the model's
    // own drafts when it has a draft layer (Settings.drafts), else guesses from the text
    private val session = Session(model, tokens, ask.maxTokens, chat.stops, prefixes, chat.marks(tokens),
      sampling(ask), guesses, anchors = chat.anchors, drafts = drafts)
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
    def close(): Unit = mlx {
      session.close()
      if session.passes > 0 then
        val what = if drafting then "drafts" else "guesses"
        System.err.println(s"[Info] $what: ${session.taken} of ${session.guessed} taken, " +
          s"${session.passes} passes of ${session.timing.tokens} tokens")
      MlxBackend.memory()
    })

object MlxBackend:
  /** MLX's memory after a request: what its arrays hold, what it keeps for reuse, the most it held */
  def memory(): Unit =
    val m = _root_.mlx.Mlx
    System.err.println(f"[Info] memory: MLX active ${m.activeMemory / 1e9}%.1f GB, kept for reuse " +
      f"${m.cacheMemory / 1e9}%.1f GB, peak ${m.peakMemory / 1e9}%.1f GB")

  /** the chat template's arguments: thinking as asked, and the model's past think blocks kept — Qwen3.6's template
   * draws them apart once a person speaks again unless asked to keep them, and a prompt whose beginning changed
   * misses the prefix cache (every new message computed the agent's last task again; mlx-scala's PrefixLawSuite) */
  def kwargs(ask: Ask): Map[String, Any] = Map("enable_thinking" -> ask.thinking, "preserve_thinking" -> true)

  /** the model of a directory, loaded on the backend's own MLX thread; its prompts' prefixes kept in memory and on
   * disk — under OKAY_MLX_PREFIXES (`off`: memory alone), else ~/.cache/okay-mlx/prefixes — so a restart does not
   * compute an agent's system prompt again. Sampling as `Settings` says: the model's generation_config.json, the
   * penalties' variables, ~/.config/okay-mlx/models.json (for clients that send none: Anthropic's API has none) */
  def open(name: String, dir: Path, mlx: OnThread = OnThread.shared, hot: Option[Int] = None): MlxBackend =
    mlx {
      // the weights mapped (mlx-scala's SafeTensors): loaded at once, the pages the file's — OKAY_MLX_MMAP=0 reads them;
      // an unaligned file aligned where it is, once (HuggingFace's blob) — OKAY_MLX_ALIGN=copy keeps it, copies it
      val mapped = !sys.env.get("OKAY_MLX_MMAP").contains("0")
      val mixture = Memory.mixture(dir)
      // the hot experts: as asked, else as the owner set them, else as the machine's memory allows
      val slots =
        if !mapped || !mixture then 0
        else hot.orElse(Settings.expertSlotsSet(name))
          .getOrElse(Memory.slotsFor(Memory.bytes(dir), Memory.room, Memory.pressure))
      if slots > 0 then System.err.println(f"[Info] $name: $slots hot experts a layer (room ${Memory.room / 1e9}%.1f GB " +
        f"for ${Memory.bytes(dir) / 1e9}%.1f, pressure ${Memory.pressure})")
      val model = Model.load(dir, mapped, inPlace = !sys.env.get("OKAY_MLX_ALIGN").contains("copy"),
        expertSlots = slots)
      val root = sys.env.get("OKAY_MLX_PREFIXES") match
        case Some("off") => None
        case Some(p) => Some(Path.of(p))
        case None => Some(Path.of(sys.props("user.home"), ".cache", "okay-mlx", "prefixes"))
      val store = root.map(r => PrefixStore.forModel(r, dir, model)).orNull
      // what MLX keeps beyond the weights, bounded: its freed buffers (a long prompt's, gigabytes, else kept whole) and
      // the prefixes in memory (on disk too: one evicted comes back from there) — unbounded, a 16k prompt on
      // Qwen3.6-35B left 23 GB active + 5 GB kept on a 38 GB machine: it paged, 0.2 tok/s until restarted
      _root_.mlx.Mlx.setCacheLimit(Memory.gigabytes("OKAY_MLX_CACHE_GB", 1.0))
      val prefixes = Memory.gigabytes("OKAY_MLX_PREFIX_GB", if store == null then 4.0 else 1.5)
      val sampling = Settings.of(name, Sampling.of(dir))
      System.err.println(s"[Info] $name samples as $sampling")
      // no guesses on hot experts: a pass of seven tokens wants up to 56 experts a layer, mostly not there
      MlxBackend(name, model, Chat.load(dir), sampling, PrefixCache(prefixes, store), mlx,
        if slots > 0 then 0 else Settings.guesses(name), if slots > 0 then 0 else Settings.drafts(name), slots, mixture,
        Memory.bytes(dir))
    }

  /** a thread all MLX calls run on: `apply(f)` runs `f` there (at once if on it already) and gives its value */
  object OnThread:
    /** THE process's: MLX's streams are the thread's that started MLX (mlx-scala keeps them once), so every model
     * of a process runs on this one */
    lazy val shared: OnThread = OnThread()
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
      chat.template(ask.messages.map(identity), ask.tools, true, kwargs(ask)))
  }

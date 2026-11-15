package okay.mlx

import okay.llm.{Ask, Llm, Timing}
import mlx.llm.Models

/** MODELS BY REQUEST: the model a request names — a repository in the HuggingFace cache that loads
 * (`mlx-community/Qwen3.5-9B-MLX-4bit`) — loaded in place of the one there, ONE in memory at a time; any other name
 * (Claude Code's `claude-…`, rozum's `claude-rozum-…` for its small requests) the one there now, so those never
 * switch it. A switch waits for the generations on the old model to end — one with no token asked for a minute
 * (its client gone) closed — then frees the old model before loading the new. All on one MLX thread.
 *
 * MANAGED (`Admin`): a model loaded or reloaded at once (`switchTo`), the memory given back (`unload`: none in memory,
 * the next request loads the one it names, else the last one), unloaded by itself after `Settings.unloadAfter`
 * minutes with nothing asked; its state read without waiting for a load (`state`) */
final class Switching(first: String, mlx: MlxBackend.OnThread = MlxBackend.OnThread.shared) extends Llm.Backend:
  private var current: MlxBackend | Null = null
  // the model to load when none is: the one there last (and its adapter)
  @volatile private var last: (String, Option[String]) = (first, None)
  private val running = scala.collection.mutable.LinkedHashSet.empty[Running]
  @volatile private var switching = false
  @volatile private var loading: Option[String] = None

  private var changed = System.nanoTime()
  private var warned = false
  @volatile private var used = System.nanoTime()
  @volatile private var lastTiming: Option[(Timing, Long)] = None
  @volatile private var snapshot: Switching.Loaded | Null = null

  // the first model: a model not there (deleted since) leaves the gateway up with none loaded
  current = try load(first) catch case e: Exception =>
    System.err.println(s"[Warn] $first did not load: ${e.getMessage}")
    null

  private def load(repo: String, hot: Option[Int] = None): MlxBackend =
    val dir = Models.snapshot(repo).getOrElse(sys.error(s"$repo is not in the HuggingFace cache"))
    System.err.println(s"[Info] loading $repo")
    loading = Some(repo)
    try
      changed = System.nanoTime()
      val b = MlxBackend.open(repo, dir, mlx, hot)
      System.err.println(f"[Info] $repo loaded: MLX holds ${mlx(_root_.mlx.Mlx.activeMemory) / 1e9}%.1f GB")
      last = (repo, b.adapter)
      snapshot = Switching.Loaded(repo, b.adapter, b.bytes, b.mixture, b.slots, System.currentTimeMillis())
      b
    finally loading = None

  private def free(): Unit =
    val c = current
    if c != null then
      last = (c.name, c.adapter)
      c.close()
      current = null
      snapshot = null
      System.err.println(f"[Info] ${c.name} closed: MLX holds ${mlx(_root_.mlx.Mlx.activeMemory) / 1e9}%.1f GB")

  def name: String =
    val (m, a) = Option(snapshot).fold(last)(s => (s.model, s.adapter))
    m + a.fold("")("+" + _)
  override def models: Vector[String] =
    val all = Models.cached().filterNot(Settings.hidden(_)).flatMap(m => m +: Adapters.of(m).map(a => s"$m+$a"))
    name +: all.filterNot(_ == name)

  /** the model for a request and its adapter: the one it names if that one loads (`<repo>+<adapter>`: with an
   * adapter that is there), else the one there now (or last) as it is */
  private def wanted(ask: Ask): (String, Option[String]) =
    ask.model.map(Adapters.split(_)).filter((m, _) => m.contains("/") && Models.cached().contains(m))
      .getOrElse(Option(current).fold(last)(c => (c.name, c.adapter)))

  /** the generations running let end (one silent for a minute: its client gone, closed) */
  private def drain(): Unit =
    while running.nonEmpty do
      val now = System.nanoTime()
      running.filter(r => !r.inside && now - r.last > Switching.abandoned).foreach(_.abandon())
      if running.nonEmpty then wait(1000)

  /** `w` with adapter `a` in memory — loaded, switched to, or (`reload`) loaded again — the generations on another
   * let end first. Called holding the lock */
  private def ensure(w: String, a: Option[String], reload: Boolean = false): MlxBackend =
    while switching do wait(1000)
    val c = current
    if c == null || reload || w != c.name || a != c.adapter then
      switching = true
      try
        drain()
        if current == null || reload || w != current.nn.name then
          free()
          current = load(w)
        current.nn.use(a)
        snapshot = snapshot.nn.copy(adapter = a)
        last = (w, a)
      finally
        switching = false
        notifyAll()
    current.nn

  /** the backend for `ask`, the model switched first if it names another — or its adapter put on or off (the model
   * not loaded again, the generations on it let end first: an adapter is the model's for all of them); held (a
   * generation) until released */
  private def hold(ask: Ask): (MlxBackend, Running) = synchronized {
    val (w, a) = wanted(ask)
    ensure(w, a)
    if running.isEmpty then fitMemory()
    used = System.nanoTime()
    val r = Running(name, Option(Switching.client.get).getOrElse("?"))
    running += r
    (current.nn, r)
  }

  /** a model (`<repo>` or `<repo>+<adapter>`) in memory now — or loaded again (`reload`: its settings read anew) */
  def switchTo(model: String, reload: Boolean): Either[String, String] =
    val (m, a) = Adapters.split(model)
    if !Models.cached().contains(m) then Left(s"$m is not in the HuggingFace cache")
    else if model.contains('+') && a.isEmpty then Left(s"no adapter ${model.drop(model.lastIndexOf('+') + 1)} for $m")
    else synchronized {
      try { ensure(m, a, reload); used = System.nanoTime(); Right(name) }
      catch case e: Exception => Left(s"$m did not load: ${e.getMessage}")
    }

  /** the model out of memory, its memory given back — unless a generation runs (`force`: they are closed) */
  def unload(force: Boolean): Either[String, Unit] = synchronized {
    while switching do wait(1000)
    if running.nonEmpty && !force then Left(s"${running.size} generation(s) running")
    else
      running.toVector.foreach(_.abandon())
      free()
      Right(())
  }

  /** unloaded by itself: nothing asked for `Settings.unloadAfter` minutes (0: never) */
  private val idle = Thread(() =>
    while true do
      Thread.sleep(30000)
      // a generation whose client is gone (the gateway failed to write to it: its stream never closed) holds the
      // model forever — "1 generation running", no unload, no memory fitting: closed after a minute of silence,
      // unless it is inside a step (a long prompt's prefill takes minutes)
      synchronized {
        val now = System.nanoTime()
        running.filter(r => !r.inside && now - r.last > Switching.abandoned).toVector.foreach { r =>
          System.err.println(s"[Warn] a generation on ${r.model} silent for a minute (its client gone): closed")
          r.abandon()
        }
        notifyAll()
      }
      val after = Settings.unloadAfter
      if after > 0 && current != null && System.nanoTime() - used > after * 60L * 1000 * 1000 * 1000 then
        synchronized {
          if running.isEmpty && !switching && current != null then
            System.err.println(s"[Info] nothing asked for $after min: the model unloaded")
            free()
        }
  , "okay-mlx-idle")
  idle.setDaemon(true)
  idle.start()

  /** THE STATE, read at once (never waiting for a load or a switch) */
  def state: Switching.State =
    val t = lastTiming
    // read without the lock (a load holds it): a copy taken as it changes is good enough for a view
    val now = try running.toVector catch case _: RuntimeException => Vector.empty
    val going = now.map(r => Switching.Going(r.model, r.client, r.prompt, r.cached, r.tokens,
      (System.nanoTime() - r.started) / 1000000L))
    Switching.State(Option(snapshot), last._1, loading, switching, going,
      if loading.nonEmpty || switching then -1L else mlx(_root_.mlx.Mlx.activeMemory),
      (System.nanoTime() - used) / 1000000000L, t)

  /** MEMORY AS IT IS NOW, before a request: a mixture of experts whole under pressure reloaded with its hot experts
   * alone; hot, and memory easy again for ten minutes, whole again — unless the owner set its hot experts. A dense
   * model under pressure: a warning (nothing to keep apart) */
  private def fitMemory(): Unit =
    val c = current.nn
    val p = Memory.pressure
    // the model's own memory counted as its room (a reload frees it first)
    val room = Memory.roomWith(Memory.room, mlx(_root_.mlx.Mlx.activeMemory), c.bytes)
    val tight = p >= 2 || room < c.bytes + c.bytes / 10
    if !c.mixture then
      if tight && !warned then
        System.err.println(f"[Warn] memory: room ${room / 1e9}%.1f GB for ${c.bytes / 1e9}%.1f, pressure $p: " +
          s"${c.name} may page")
      warned = tight
    else if Settings.expertSlotsSet(c.name).isEmpty then
      val want = Memory.slotsWanted(c.slots, c.bytes, room, p, System.nanoTime() - changed)
      if want != c.slots then
        System.err.println(f"[Warn] memory: room ${room / 1e9}%.1f GB for ${c.bytes / 1e9}%.1f, pressure $p: " +
          s"${c.name} " + (if want > 0 then s"reloaded with $want hot experts a layer" else "reloaded whole"))
        val (name, a) = (c.name, c.adapter)
        free()
        current = load(name, Some(want))
        current.nn.use(a)
        snapshot = snapshot.nn.copy(adapter = a)

  /** a generation going on: its model and client, its prompt (and how much a cache gave), its tokens so far */
  private final class Running(val model: String, val client: String):
    val started: Long = System.nanoTime()
    @volatile var tokens = 0
    @volatile var prompt = -1
    @volatile var cached = 0
    @volatile var last: Long = System.nanoTime()
    /** inside a step now (a prefill may take minutes): not silent */
    @volatile var inside = false
    @volatile var generation: Llm.Generation | Null = null
    def release(): Unit = Switching.this.synchronized {
      running -= this
      used = System.nanoTime()
      Switching.this.notifyAll() }
    def abandon(): Unit =
      val g = generation
      if g != null then g.close()
      running -= this

  def count(ask: Ask): Int =
    val (b, r) = hold(ask)
    try b.count(ask) finally r.release()

  def start(ask: Ask): Llm.Generation =
    val (b, r) = hold(ask)
    val g = try b.start(ask) catch case e: Throwable => { r.release(); throw e }
    r.generation = g
    new Llm.Generation:
      private var done = false
      def next(): Option[String] =
        r.last = System.nanoTime()
        r.inside = true
        val piece = try g.next() finally { r.inside = false; r.last = System.nanoTime() }
        if piece.nonEmpty then
          r.tokens += 1
          // the prompt's size once its prefill is done (read on this thread, between tokens)
          if r.prompt < 0 then
            try { val t = g.timing; r.prompt = t.promptTokens; r.cached = t.cachedTokens }
            catch case _: Exception => r.prompt = 0
        piece
      def text: String = g.text
      def timing: Timing = g.timing
      def byStop: Boolean = g.byStop
      def close(): Unit = if !done then
        done = true
        try lastTiming = Some((g.timing, System.currentTimeMillis())) catch case _: Exception => ()
        g.close()
        r.release()

object Switching:
  /** a generation with no token asked for this long: its client gone */
  val abandoned: Long = 60L * 1000 * 1000 * 1000

  /** the model in memory: its name, adapter, weights' bytes, whether a mixture of experts and its hot experts a
   * layer (0: whole), when it loaded (ms since the epoch) */
  final case class Loaded(model: String, adapter: Option[String], bytes: Long, mixture: Boolean, slots: Int,
      since: Long)
  /** `loaded`: none when unloaded; `last`: the model the next request loads by default; `loading`: one loading now;
   * `held`: MLX's active memory (bytes, -1 when the MLX thread is busy); the last generation's timing and when */
  /** the client of the request this thread serves (`Main` sets it from the request's User-Agent): the gateway runs a
   * request on the thread that accepted it */
  val client: ThreadLocal[String] = ThreadLocal()

  /** a generation going on, as the panel shows it: prompt -1 while its prefill runs */
  final case class Going(model: String, client: String, prompt: Int, cached: Int, tokens: Int, millis: Long):
    def perSecond: Double = if millis <= 0 then 0 else tokens * 1000.0 / millis

  final case class State(loaded: Option[Loaded], last: String, loading: Option[String], switching: Boolean,
      going: Vector[Going], held: Long, idleSeconds: Long, lastTiming: Option[(Timing, Long)])

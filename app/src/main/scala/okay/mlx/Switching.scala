package okay.mlx

import okay.llm.{Ask, Llm, Timing}
import mlx.llm.Models

/** MODELS BY REQUEST: the model a request names — a repository in the HuggingFace cache that loads
 * (`mlx-community/Qwen3.5-9B-MLX-4bit`) — loaded in place of the one there, ONE in memory at a time; any other name
 * (Claude Code's `claude-…`, rozum's `claude-rozum-…` for its small requests) the one there now, so those never
 * switch it. A switch waits for the generations on the old model to end — one with no token asked for a minute
 * (its client gone) closed — then frees the old model before loading the new. All on one MLX thread */
final class Switching(first: String, mlx: MlxBackend.OnThread = MlxBackend.OnThread.shared) extends Llm.Backend:
  private var current: MlxBackend = load(first)
  private val running = scala.collection.mutable.LinkedHashSet.empty[Running]
  private var switching = false

  private var changed = System.nanoTime()
  private var warned = false

  private def load(repo: String, hot: Option[Int] = None): MlxBackend =
    val dir = Models.snapshot(repo).getOrElse(sys.error(s"$repo is not in the HuggingFace cache"))
    System.err.println(s"[Info] loading $repo")
    changed = System.nanoTime()
    val b = MlxBackend.open(repo, dir, mlx, hot)
    System.err.println(f"[Info] $repo loaded: MLX holds ${mlx(_root_.mlx.Mlx.activeMemory) / 1e9}%.1f GB")
    b

  def name: String = synchronized(current.name)
  override def models: Vector[String] = synchronized(current.name +: Models.cached().filterNot(_ == current.name))

  /** the model for a request: the one it names if that one loads, else the one there now */
  private def wanted(ask: Ask): String =
    ask.model.filter(m => m.contains("/") && Models.cached().contains(m)).getOrElse(current.name)

  /** the backend for `ask`, the model switched first if it names another; held (a generation) until released */
  private def hold(ask: Ask): (MlxBackend, Running) = synchronized {
    // a switch going on: every request waits for it (no new generation on the old model holds it up)
    while switching do wait(1000)
    val w = wanted(ask)
    if w != current.name then
      switching = true
      try
        while running.nonEmpty do
          val now = System.nanoTime()
          running.filter(r => now - r.last > Switching.abandoned).foreach(_.abandon())
          if running.nonEmpty then wait(1000)
        current.close()
        System.err.println(f"[Info] ${current.name} closed: MLX holds ${mlx(_root_.mlx.Mlx.activeMemory) / 1e9}%.1f GB")
        current = load(w)
      finally
        switching = false
        notifyAll()
    if running.isEmpty then fitMemory()
    val r = Running()
    running += r
    (current, r)
  }

  /** MEMORY AS IT IS NOW, before a request: a mixture of experts whole under pressure reloaded with its hot experts
   * alone; hot, and memory easy again for ten minutes, whole again — unless the owner set its hot experts. A dense
   * model under pressure: a warning (nothing to keep apart) */
  private def fitMemory(): Unit =
    val p = Memory.pressure
    // the model's own memory counted as its room (a reload frees it first)
    val room = Memory.roomWith(Memory.room, mlx(_root_.mlx.Mlx.activeMemory), current.bytes)
    val tight = p >= 2 || room < current.bytes + current.bytes / 10
    if !current.mixture then
      if tight && !warned then
        System.err.println(f"[Warn] memory: room ${room / 1e9}%.1f GB for ${current.bytes / 1e9}%.1f, pressure $p: " +
          s"${current.name} may page")
      warned = tight
    else if Settings.expertSlotsSet(current.name).isEmpty then
      val want = Memory.slotsWanted(current.slots, current.bytes, room, p, System.nanoTime() - changed)
      if want != current.slots then
        System.err.println(f"[Warn] memory: room ${room / 1e9}%.1f GB for ${current.bytes / 1e9}%.1f, pressure $p: " +
          s"${current.name} " + (if want > 0 then s"reloaded with $want hot experts a layer" else "reloaded whole"))
        val name = current.name
        current.close()
        current = load(name, Some(want))

  private final class Running:
    @volatile var last: Long = System.nanoTime()
    @volatile var generation: Llm.Generation | Null = null
    def release(): Unit = Switching.this.synchronized { running -= this; Switching.this.notifyAll() }
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
        g.next()
      def text: String = g.text
      def timing: Timing = g.timing
      def byStop: Boolean = g.byStop
      def close(): Unit = if !done then
        done = true
        g.close()
        r.release()

object Switching:
  /** a generation with no token asked for this long: its client gone */
  val abandoned: Long = 60L * 1000 * 1000 * 1000

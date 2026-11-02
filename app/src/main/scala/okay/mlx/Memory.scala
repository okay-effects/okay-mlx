package okay.mlx

import java.nio.file.{Files, Path}
import okay.effects.json.Json

/** THE MACHINE'S MEMORY, as it bears on a model: macOS's pressure (1 normal, 2 warning, 4 critical) and the share
 * free. A mixture of experts mapped whole, under pressure, pages its experts in and out — Metal brings a layer's
 * experts in whole when a kernel uses them, and the OS takes them back: a decode at 0.1–0.3 tok/s, seen. Its hot
 * experts alone hold (mlx-scala's ExpertCache): under a warning 64 a layer (Qwen3.6-35B ~6 GB), critical 32 */
object Memory:
  def pressure: Int = _root_.mlx.Mlx.memoryPressure
  def freePercent: Int = _root_.mlx.Mlx.memoryFreePercent
  /** the room a mapped model's pages have (the OS's file cache and what is free), bytes */
  def room: Long = _root_.mlx.Mlx.memoryRoom

  /** the experts a layer a mixture of experts of `bytes` should keep, given the room and the pressure: whole (0) when
   * it fits — with a tenth to spare, no pressure; 64 a layer when it does not; 32 when not half of it does, or the
   * pressure is critical. (The pressure alone said normal while others' compressed memory left 16.7 GB of 38 for a
   * model of 19.5: it paged, 0.2 tok/s) */
  def slotsFor(bytes: Long, room: Long, pressure: Int): Int =
    if pressure >= 4 || room < bytes / 2 then 32
    else if pressure >= 2 || room < bytes + bytes / 10 then 64
    else 0

  /** the hot experts a mixture of experts running with `now` (0: whole) should run with: whole and not fitting →
   * hot; hot, room for a fifth more than it, the last change `sinceNanos` ago — ten minutes or more → whole. (Half as
   * much again, before: never on a 38 GB machine with an IDE and a browser open — stuck hot, where a prompt's prefill
   * reads the mapped experts whole: 8.5 s for 500 tokens on 2.7k cached, whole 0.4 s; decode 10 against 110 tok/s) */
  def slotsWanted(now: Int, bytes: Long, room: Long, pressure: Int, sinceNanos: Long): Int =
    if now == 0 then slotsFor(bytes, room, pressure)
    else if pressure == 1 && room > bytes + bytes / 5 && sinceNanos > 10L * 60 * 1000 * 1000 * 1000 then 0
    else now

  /** a size set in gigabytes by a variable, else `default`; bytes */
  def gigabytes(variable: String, default: Double): Long =
    (sys.env.get(variable).flatMap(_.toDoubleOption).getOrElse(default) * 1e9).toLong

  /** a model's weights, bytes: its .safetensors */
  def bytes(dir: Path): Long =
    Files.list(dir).toArray.map(_.asInstanceOf[Path]).filter(_.toString.endsWith(".safetensors"))
      .map(p => Files.size(p.toRealPath())).sum

  /** whether a model is a mixture of experts (config.json: experts) */
  def mixture(dir: Path): Boolean =
    val f = dir.resolve("config.json")
    Files.exists(f) && {
      val j = Json.fromText(Files.readString(f))
      val t = j.field("text_config").getOrElse(j)
      t.field("num_experts").exists(_.int > 0)
    }

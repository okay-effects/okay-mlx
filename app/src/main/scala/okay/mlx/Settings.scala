package okay.mlx

import java.nio.file.{Files, Path}
import okay.effects.json.Json
import mlx.llm.Sampling

/** A MODEL'S SAMPLING, as the machine's owner wants it: ~/.config/okay-mlx/models.json (or OKAY_MLX_MODELS), by
 * model, `"*"` for every one —
 * {{{
 * {"*": {"presence_penalty": 1.5},
 *  "mlx-community/Qwen3.6-35B-A3B-4bit": {"temperature": 0.6, "top_p": 0.95, "top_k": 20, "presence_penalty": 0}}
 * }}}
 * Over the model's own (generation_config.json) and OKAY_MLX_PRESENCE_PENALTY / OKAY_MLX_FREQUENCY_PENALTY; a
 * request's own fields over all of it. Read when a model loads: an edit holds from the next load */
object Settings:
  def file: Path = sys.env.get("OKAY_MLX_MODELS").map(Path.of(_))
    .getOrElse(Path.of(sys.props("user.home"), ".config", "okay-mlx", "models.json"))

  def of(name: String, model: Sampling, settings: Option[Json] = read()): Sampling =
    def env(k: String) = sys.env.get(k).flatMap(_.toDoubleOption)
    val base = model.copy(presencePenalty = env("OKAY_MLX_PRESENCE_PENALTY").getOrElse(model.presencePenalty),
      frequencyPenalty = env("OKAY_MLX_FREQUENCY_PENALTY").getOrElse(model.frequencyPenalty))
    Seq("*", name).flatMap(k => settings.flatMap(_.field(k))).foldLeft(base)(over)

  private def over(s: Sampling, j: Json): Sampling =
    def d(k: String) = j.field(k).map(_.double)
    Sampling(d("temperature").getOrElse(s.temperature), d("top_p").getOrElse(s.topP),
      j.field("top_k").map(_.int).getOrElse(s.topK), j.field("seed").map(_.long).orElse(s.seed),
      d("presence_penalty").getOrElse(s.presencePenalty), d("frequency_penalty").getOrElse(s.frequencyPenalty))

  /** HOT EXPERTS: how many experts a layer a mixture of experts keeps in memory (mlx-scala's ExpertCache), the rest
   * read from the files as picked — `"expert_slots"` by model (or `"*"`), else OKAY_MLX_EXPERT_SLOTS; 0: all of them.
   * Qwen3.6-35B, 64 a layer: ~6 GB instead of 19.5, the decode ~45 tok/s instead of ~119 */
  def expertSlots(name: String, settings: Option[Json] = read()): Int =
    Seq(name, "*").flatMap(k => settings.flatMap(_.field(k)).flatMap(_.field("expert_slots"))).headOption.map(_.int)
      .orElse(sys.env.get("OKAY_MLX_EXPERT_SLOTS").flatMap(_.toIntOption)).getOrElse(0)

  def read(): Option[Json] =
    val f = file
    if !Files.exists(f) then None
    else
      try Some(Json.fromText(Files.readString(f)))
      catch case e: Exception =>
        System.err.println(s"[Warn] $f: ${e.getMessage} — not used")
        None

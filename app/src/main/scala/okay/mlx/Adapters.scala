package okay.mlx

import java.nio.file.{Files, Path}

/** ADAPTERS (LoRA, mlx-scala's `Lora`, trained by okay-forge): a model asked as `<repo>+<adapter>` —
 * `mlx-community/Qwen3.5-4B-MLX-4bit+okay` — runs with the adapter put on it, the model not loaded again. An adapter
 * is a file per model: OKAY_MLX_ADAPTERS, else ~/.okay-mlx/adapters, then `<adapter>/<org>--<name>.safetensors` */
object Adapters:
  def dir: Path = sys.env.get("OKAY_MLX_ADAPTERS").map(Path.of(_))
    .getOrElse(Path.of(sys.props("user.home"), ".okay-mlx", "adapters"))

  def path(adapter: String, repo: String, root: Path = dir): Path =
    root.resolve(adapter).resolve(repo.replace("/", "--") + ".safetensors")

  /** a model's name split: the repository, and the adapter if it names one that is there */
  def split(name: String, root: Path = dir): (String, Option[String]) =
    name.lastIndexOf('+') match
      case -1 => (name, None)
      case i =>
        val (repo, a) = (name.take(i), name.drop(i + 1))
        if a.nonEmpty && Files.exists(path(a, repo, root)) then (repo, Some(a)) else (name, None)

  /** the adapters there for a repository */
  def of(repo: String, root: Path = dir): Vector[String] =
    if !Files.isDirectory(root) then Vector.empty
    else Files.list(root).toArray.map(_.asInstanceOf[Path])
      .filter(d => Files.exists(path(d.getFileName.toString, repo, root))).map(_.getFileName.toString).sorted.toVector

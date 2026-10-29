package okay.mlx

import java.nio.file.Path
import okay.scala3.*
import okay.scala3.std.*
import mlx.llm.*

/** `ask <question>` — one answer; `bench [runs] [source file]` — prefill and decode speed at three prompt sizes;
 * `serve [port]` — the gateway (OpenAI's and Anthropic's APIs, 127.0.0.1:8090). The model: MLX_MODEL (a HuggingFace
 * repository in the cache), mlx-community/Qwen3-4B-4bit by default */
@main def okayMlx(args: String*): Unit =
  val repo = sys.env.getOrElse("MLX_MODEL", "mlx-community/Qwen3-4B-4bit")
  val platform = if System.getProperty("java.vm.name", "").contains("Scala Native") then "native" else "jvm"
  val stderr = (l: Level, m: String) => System.err.println(s"[$l] $m")

  type Find[X] = (Files + Log)[X]
  def find: Path ! Find =
    for
      dir <- Files.snapshot[Find](repo).map(_.getOrElse(sys.error(s"$repo is not in the HuggingFace cache")))
      _ <- Log.info[Find](s"$repo at $dir")
    yield dir
  val dir = run(Log.to(stderr, Level.Info)(Files.disk(find)))
  val chat = Chat.load(dir)
  val model = Model.load(dir)

  type App[X] = (Llm + Console + Clock + Log)[X]
  def go[A](p: A ! App): A =
    run(Log.to(stderr, Level.Info)(Clock.system(Console.stdout(Llm.mlx(repo, model, chat)(p)))))
  args.toList match
    case "ask" :: words => go(Programs.ask[App](words.mkString(" "), 256))
    case "bench" :: rest =>
      val runs = rest.headOption.map(_.toInt).getOrElse(3)
      val source = rest.drop(1).headOption.map(Path.of(_))
        .getOrElse(Path.of(sys.props("user.home"), "work/my/okay-rust/src/typed.rs"))
      val text = run(Files.disk(Files.read[Files](source)))
      go(Programs.ask[App]("Say hello.", 8))     // warm-up: the kernels compiled
      go(Programs.bench[App](s"okay-mlx-$platform", text, Seq(400, 16000, 32000), runs, 256))
    case "serve" :: rest =>
      type Gw[X] = (Llm + Http + Clock + Fresh + Log)[X]
      Server.run(rest.headOption.map(_.toInt).getOrElse(8090)) { (req, out) =>
        run(Log.to(stderr, Level.Info)(Fresh.from(0)(Clock.system(Http.socket(out)(
          Llm.mlx(repo, model, chat)(Gateway.route[Gw](req)))))))
      }
    case _ => System.err.println("usage: ask <question> | bench [runs] [source file] | serve [port]")
  model.close()

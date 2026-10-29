package okay.mlx

import okay.scala3.*
import okay.llm.*
import mlx.llm.Models

/** the gateway's programs on the real model — when mlx-community/Qwen3-4B-4bit is in the HuggingFace cache */
class MlxBackendSuite extends munit.FunSuite:
  override val munitTimeout = scala.concurrent.duration.Duration(5, "min")
  private lazy val dir = Models.snapshot("mlx-community/Qwen3-4B-4bit")

  test("a question through Llm.on(MlxBackend)"):
    assume(dir.isDefined, "mlx-community/Qwen3-4B-4bit is not in the HuggingFace cache")
    val backend = MlxBackend.open("qwen3-4b", dir.get)
    val f = run(Llm.on(backend)(Llm.complete[Llm](Programs.user("What is the capital of France? One word.")
      .copy(maxTokens = 16))))
    assert(f.reply.content.contains("Paris"), f.reply.content)
    assert(f.byStop)

/** the gateway's models by request: the one a request names loaded in place; Claude's names never switch it */
class SwitchingSuite extends munit.FunSuite:
  override val munitTimeout = scala.concurrent.duration.Duration(5, "min")
  private val a = "mlx-community/Qwen3-4B-4bit"
  private val b = "mlx-community/Qwen3.5-4B-MLX-4bit"

  test("a request naming another model switches to it; claude-… and unknown names do not"):
    assume(Models.snapshot(a).isDefined && Models.snapshot(b).isDefined, s"$a and $b are not both in the cache")
    val backend = Switching(a)
    def ask(model: Option[String]) = run(Llm.on(backend)(Llm.complete[Llm](Programs.user(
      "What is the capital of France? One word.").copy(maxTokens = 16, model = model))))
    assert(ask(Some("claude-haiku-4-5")).reply.content.contains("Paris"))
    assertEquals(backend.name, a)
    assert(ask(Some(b)).reply.content.contains("Paris"))
    assertEquals(backend.name, b)
    assertEquals(backend.models.head, b)
    ask(Some("claude-rozum-mlx-community-Qwen3-4B-4bit"))
    ask(Some("nobody/no-such-model"))
    assertEquals(backend.name, b)
    ask(Some(a))
    assertEquals(backend.name, a)

  test("a switch waits for the old model's generation to end"):
    assume(Models.snapshot(a).isDefined && Models.snapshot(b).isDefined, s"$a and $b are not both in the cache")
    val backend = Switching(a)
    val g = backend.start(Programs.user("Count from one to twenty.").copy(maxTokens = 64, model = Some(a)))
    g.next()
    val switched = scala.concurrent.Promise[String]()
    val other: Runnable = () =>
      backend.count(Programs.user("hi").copy(model = Some(b)))
      switched.success(backend.name)
    Thread(other).start()
    Thread.sleep(1500)
    assert(!switched.isCompleted, "switched while a generation ran on the old model")
    Iterator.continually(g.next()).takeWhile(_.isDefined).foreach(_ => ())
    g.close()
    assertEquals(scala.concurrent.Await.result(switched.future, scala.concurrent.duration.Duration(2, "min")), b)

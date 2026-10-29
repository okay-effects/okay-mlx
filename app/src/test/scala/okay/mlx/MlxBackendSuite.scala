package okay.mlx

import okay.scala3.*
import okay.llm.*
import mlx.llm.{Chat, Model, Models}

/** the gateway's programs on the real model — when mlx-community/Qwen3-4B-4bit is in the HuggingFace cache */
class MlxBackendSuite extends munit.FunSuite:
  override val munitTimeout = scala.concurrent.duration.Duration(5, "min")
  private lazy val dir = Models.snapshot("mlx-community/Qwen3-4B-4bit")

  test("a question through Llm.on(MlxBackend)"):
    assume(dir.isDefined, "mlx-community/Qwen3-4B-4bit is not in the HuggingFace cache")
    val backend = MlxBackend("qwen3-4b", Model.load(dir.get), Chat.load(dir.get))
    val f = run(Llm.on(backend)(Llm.complete[Llm](Programs.user("What is the capital of France? One word.")
      .copy(maxTokens = 16))))
    assert(f.reply.content.contains("Paris"), f.reply.content)
    assert(f.byStop)

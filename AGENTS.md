# okay-mlx — notes for agents

Language models on mlx-scala with okay-scala's effects; JVM (FFM) and Scala Native. One crossProject, `app/`,
package `okay.mlx`.

- Depends on mlx-scala `0.1.0-SNAPSHOT` by `publishLocal` (../mlx-scala) and on its native libraries:
  `MLX_SCALA_LIB`, else `../mlx-scala/native-lib/out/lib`. okay-scala 0.1.1 from its Pages repository.
- `Effects.scala`: `Llm` (mlx, fake), `Files`, `Console`, `Http` (socket, collect); `Ask`, `Gen`, `Finished`,
  `Request`. `Api.scala`: pure — `Streamer` (thinking / text / held-back tool calls, a tag's beginning waits),
  `OpenAi`, `Anthropic` (requests as `Ask`, turns as JSON or stream chunks). `Gateway.scala`: the routes as
  programs. `Server.scala`: HTTP/1.1 on ServerSocket. `Programs.scala`: ask, bench. `Main.scala`: wiring.
- Every program is tested under fake/collect/virtual handlers (`GatewaySuite`, `ProgramsSuite`) on both platforms.
- Scala Native's regex is RE2's: no look-around. No `java.time`.

Build: `sbt test`, `sbt "appJVM/run serve 8090"`, `sbt "appNative/run bench 3"`. Lines at most 120 characters.

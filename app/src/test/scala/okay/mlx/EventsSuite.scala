package okay.mlx

import okay.effects.json.Json
import okay.scala3.*
import okay.scala3.std.*
import okay.llm.{Http, Request}

/** THE GATEWAY'S EVENTS: each change an event of its type, once; `memory.room` at once when the room is there;
 * heartbeats in silence; the MCP endpoint's handshake declares the extension — over a script of the machine and a
 * virtual clock, no model */
class EventsSuite extends munit.FunSuite:
  import Events.*
  type Ev[X] = (Gauge + Clock + Http)[X]
  val idle = Snap(None, 5_000_000_000L, None, None)

  /** a stream over `snaps`: its frames' JSON */
  def frames(sub: Sub, snaps: Vector[Snap]): Vector[Json] =
    val ((status, kind, body), _) = run(Http.collect(Clock.virtual(0)(Gauge.script(snaps)(
      Events.stream[Ev](sub, Json.num(7))))))
    assertEquals((status, kind), (200, "text/event-stream"))
    body.split("\n\n").toVector.filter(_.startsWith("data: ")).map(l => Json.fromText(l.stripPrefix("data: ")))

  def methods(fs: Vector[Json]) = fs.map(_("method").string.stripPrefix("notifications/events/"))

  test("a model loaded, then another: loaded and unloaded, each once, each in the right stream"):
    val snaps = Vector(idle, idle.copy(model = Some("A")), idle.copy(model = Some("A")), idle.copy(model = Some("B")))
    val loaded = frames(Sub("model.loaded", 0), snaps)
    assertEquals(methods(loaded), Vector("active", "event", "event"))
    assertEquals(loaded.drop(1).map(_("params")("data")("model").string), Vector("A", "B"))
    assert(loaded.forall(_("params")("_meta")(SubscriptionId) == Json.num(7)))
    val unloaded = frames(Sub("model.unloaded", 0), snaps)
    assertEquals(unloaded.drop(1).map(_("params")("data")("model").string), Vector("A"))

  test("memory.room: at once when the room is there; else when it reaches min_gb, once"):
    assertEquals(methods(frames(Sub("memory.room", 4), Vector(idle))), Vector("active", "event"))
    val low = idle.copy(room = 2_000_000_000L)
    val fs = frames(Sub("memory.room", 4), Vector(low, low, idle, idle, low, idle))
    assertEquals(methods(fs), Vector("active", "event", "event"))
    assertEquals(fs(1)("params")("data")("room_gb"), Json.num(5.0))

  test("gpu.starved and gpu.freed; generation.done once a generation"):
    val starved = idle.copy(starved = Some(("Q", 200000L)))
    val done = idle.copy(done = Some((99L, "Q", 12L, 33.3)))
    val snaps = Vector(idle, starved, starved, idle, done, done)
    assertEquals(methods(frames(Sub("gpu.starved", 0), snaps)), Vector("active", "event"))
    assertEquals(methods(frames(Sub("gpu.freed", 0), snaps)), Vector("active", "event"))
    val g = frames(Sub("generation.done", 0), snaps)
    assertEquals(methods(g), Vector("active", "event"))
    assertEquals(g(1)("params")("data")("tokens"), Json.num(12))

  test("iso: epoch milliseconds as the same instant java.time gives"):
    for ms <- Vector(0L, 951782400000L, 1795429647060L, 4102444799000L, 1709164800000L) do
      assertEquals(iso(ms), java.time.Instant.ofEpochSecond(ms / 1000).toString)

  test("silence: a heartbeat every 20 s, none while events come"):
    val fs = frames(Sub("model.loaded", 0), Vector.fill(45)(idle))   // 44 s of polls at 1 s
    assertEquals(methods(fs).count(_ == "heartbeat"), 2)

  test("the endpoint: initialize declares the extension; events/list the six types; an unknown stream refused"):
    def call(body: String): Json =
      val ((_, _, out), _) = run(Http.collect(Clock.virtual(0)(Gauge.script(Vector.empty)(
        Mcp.route[Ev](Request("POST", "/mcp", Map.empty, body), () => Json.obj())))))
      Json.fromText(out)
    val init = call("""{"jsonrpc":"2.0","id":0,"method":"initialize","params":{"protocolVersion":"2025-11-25"}}""")
    assert(init("result")("capabilities")("extensions").field(Extension).nonEmpty, init.render)
    val list = call("""{"jsonrpc":"2.0","id":1,"method":"events/list"}""")
    assertEquals(list("result")("events").list.map(_("name").string), names)
    val bad = call("""{"jsonrpc":"2.0","id":2,"method":"events/stream","params":{"name":"nope"}}""")
    assertEquals(bad("error")("code"), Json.num(-32602))

package okay.mlx

import okay.effects.json.Json
import okay.scala3.*
import okay.scala3.std.*
import okay.llm.{Http, Request}

/** THE GATEWAY'S EVENTS, as the draft MCP extension `io.modelcontextprotocol/events` has them (rozum's
 * docs/specs/mcp-events.md: what opencode ≥ 2.3 speaks): an MCP endpoint `/mcp` on the gateway's port with a `status`
 * tool and event types an agent — or okay-loop — sleeps on instead of polling /admin/status:
 *
 *  - `model.loaded` / `model.unloaded` {model};
 *  - `memory.room` {room_gb} — arguments `{min_gb}`: the room for MLX reached it (at once if it is there already);
 *  - `gpu.starved` {model, minutes} / `gpu.freed` {} — a generation with no token for 3 minutes (other work holds the
 *    GPU), and the end of that;
 *  - `generation.done` {model, tokens, decode_per_second}.
 *
 * Push only (`events/stream`: `active`, the events, a heartbeat every 20 s — opencode drops a stream silent 60 s); no
 * replay (`cursor: null`: what happened before the subscription is the status tool's). The machine is an effect
 * (`Gauge`), the stream a program over it, the clock and the response */
object Events:
  val Extension = "io.modelcontextprotocol/events"
  val SubscriptionId = "io.modelcontextprotocol/subscriptionId"
  val HeartbeatMs = 20000L
  val StarvedMs = 180000L

  /** the machine at a moment: the model in memory, the room for MLX (bytes), a starved generation (its model and how
   * long), the last generation done (its time, model, tokens, speed) */
  final case class Snap(model: Option[String], room: Long, starved: Option[(String, Long)],
      done: Option[(Long, String, Long, Double)])

  object Snap:
    def of(st: Switching.State, room: Long): Snap = Snap(st.loaded.map(_.model), room,
      st.going.find(g => g.tokens == 0 && g.millis > StarvedMs).map(g => (g.model, g.millis)),
      st.lastTiming.map((t, at) => (at, st.last, t.tokens.toLong, math.round(t.decodePerSecond * 10) / 10.0)))

  /** THE MACHINE, read: a snapshot, or none when the stream is to end (the gateway closing; a script's end) */
  enum Gauge[X]:
    case Read() extends Gauge[Option[Snap]]

  object Gauge:
    def read[R[_]](using In[Gauge, R]): Option[Snap] ! R = perform[Gauge](Read())
    /** the gateway's own state */
    def of[R[_], Rest[_], A](sw: Switching)(p: A ! R)(using Split[Gauge, R, Rest]): A ! Rest =
      handle(p, Handler.tail[Gauge, Rest, A, A](pure)([X] => (op: Gauge[X]) => op match
        case Read() => Some(Snap.of(sw.state, Memory.room))))
    /** a script of snapshots, then the end */
    def script[R[_], Rest[_], A](snaps: Vector[Snap])(p: A ! R)(using Split[Gauge, R, Rest]): A ! Rest =
      handle(p, Handler.stateful[Gauge, Rest, A, A, Int](0)((_, a) => pure(a))(
        [X] => (op: Gauge[X], at: Cell[Int]) => op match
          case Read() => val i = at.get; at.set(i + 1); snaps.lift(i)))

  /** epoch milliseconds as ISO 8601 UTC (Scala Native has no java.time): days to a civil date, Hinnant's way */
  def iso(ms: Long): String =
    val days = Math.floorDiv(ms, 86400000L)
    val secs = Math.floorMod(ms, 86400000L) / 1000
    val z = days + 719468
    val era = Math.floorDiv(z, 146097L)
    val doe = z - era * 146097
    val yoe = (doe - doe / 1460 + doe / 36524 - doe / 146096) / 365
    val doy = doe - (365 * yoe + yoe / 4 - yoe / 100)
    val mp = (5 * doy + 2) / 153
    val d = doy - (153 * mp + 2) / 5 + 1
    val m = if mp < 10 then mp + 3 else mp - 9
    val y = yoe + era * 400 + (if m <= 2 then 1 else 0)
    f"$y%04d-$m%02d-$d%02dT${secs / 3600}%02d:${secs % 3600 / 60}%02d:${secs % 60}%02dZ"

  private def s(x: String): Json = Json.Str(x)
  private def gb(bytes: Long): Double = math.round(bytes / 1e8) / 10.0

  val names: Vector[String] =
    Vector("model.loaded", "model.unloaded", "memory.room", "gpu.starved", "gpu.freed", "generation.done")

  def descriptors: Json =
    def obj(props: (String, String)*) = Json.obj("type" -> s("object"), "properties" -> Json.Obj(props.toVector.map(
      (n, t) => n -> Json.obj("type" -> s(t)))))
    def one(name: String, what: String, input: Json, payload: Json) = Json.obj("name" -> s(name),
      "description" -> s(what), "delivery" -> Json.arr(s("push")), "inputSchema" -> input, "payloadSchema" -> payload)
    val none = obj()
    Json.Arr(Vector(
      one("model.loaded", "A model was loaded into memory", none, obj("model" -> "string")),
      one("model.unloaded", "The model in memory was unloaded", none, obj("model" -> "string")),
      one("memory.room", "The machine's room for MLX reached min_gb (at once if it has it already)",
        Json.obj("type" -> s("object"), "properties" -> Json.obj("min_gb" -> Json.obj("type" -> s("number")))),
        obj("room_gb" -> "number")),
      one("gpu.starved", "A generation has had no token for 3 minutes: other work holds the GPU", none,
        obj("model" -> "string", "minutes" -> "number")),
      one("gpu.freed", "The starved generation got its tokens, or ended", none, none),
      one("generation.done", "A generation ended", none,
        obj("model" -> "string", "tokens" -> "integer", "decode_per_second" -> "number"))))

  /** what a stream listens for */
  final case class Sub(name: String, minGb: Double)

  /** the events from `before` to `after` for `sub`: (name, data) */
  def diff(before: Snap, after: Snap, sub: Sub): Vector[Json] =
    val min = (sub.minGb * 1e9).toLong
    val all: Vector[(String, Json)] =
      (if after.model != before.model then
        before.model.map(m => "model.unloaded" -> Json.obj("model" -> s(m))).toVector ++
          after.model.map(m => "model.loaded" -> Json.obj("model" -> s(m))).toVector
      else Vector.empty) ++
      (if after.room >= min && before.room < min then
        Vector("memory.room" -> Json.obj("room_gb" -> Json.num(gb(after.room)))) else Vector.empty) ++
      ((before.starved, after.starved) match
        case (None, Some((m, ms))) => Vector("gpu.starved" -> Json.obj("model" -> s(m),
          "minutes" -> Json.num(math.round(ms / 6000.0) / 10.0)))
        case (Some(_), None) => Vector("gpu.freed" -> Json.obj())
        case _ => Vector.empty) ++
      (after.done match
        case Some((at, m, tokens, speed)) if !before.done.exists(_._1 == at) =>
          Vector("generation.done" -> Json.obj("model" -> s(m), "tokens" -> Json.num(tokens),
            "decode_per_second" -> Json.num(speed)))
        case _ => Vector.empty)
    all.collect { case (n, d) if n == sub.name => d }

  private def frame(method: String, params: Json, id: Json): String =
    val p = Json.Obj(params.record :+ ("_meta" -> Json.obj(SubscriptionId -> id)))
    s"data: ${Json.obj("jsonrpc" -> s("2.0"), "method" -> s(method), "params" -> p).render}\n\n"

  /** a push stream: `active`; `memory.room` at once if the room is there; then each change an event, a heartbeat
   * after `HeartbeatMs` of nothing; until the gauge ends. `poll`: between reads */
  def stream[R[_]](sub: Sub, id: Json, poll: Long = 1000)(using In[Gauge, R], In[Clock, R], In[Http, R])
      : Unit ! R =
    var n = 0
    def event(data: Json, now: Long) =
      n += 1
      Http.send[R](frame("notifications/events/event", Json.obj("eventId" -> s(s"${sub.name}-$now-$n"),
        "name" -> s(sub.name), "timestamp" -> s(iso(now)), "data" -> data,
        "cursor" -> Json.Null), id))
    for
      _ <- Http.open[R](200, "text/event-stream")
      _ <- Http.send[R](frame("notifications/events/active", Json.obj("cursor" -> Json.Null,
        "truncated" -> Json.Bool(false), "heartbeatMs" -> Json.num(HeartbeatMs)), id))
      first <- Gauge.read[R]
      t0 <- Clock.now[R]
      // already there: the waiter is not kept waiting for an edge that will not come
      _ <- first match
        case Some(f) if sub.name == "memory.room" && f.room >= (sub.minGb * 1e9).toLong =>
          event(Json.obj("room_gb" -> Json.num(gb(f.room))), t0)
        case _ => unit[R]
      _ <- loop[(Option[Snap], Long), Unit, R]((first, t0)) { (last, quiet) =>
        last match
          case None => pure(Right(()))
          case Some(before) =>
            for
              _ <- Clock.sleep[R](poll)
              next <- Gauge.read[R]
              now <- Clock.now[R]
              evs = next.fold(Vector.empty[Json])(diff(before, _, sub))
              _ <- evs.foldLeft(unit[R])((acc, d) => acc.andThen(event(d, now)))
              beat = evs.isEmpty && now - quiet >= HeartbeatMs
              _ <- if beat then Http.send[R](frame("notifications/events/heartbeat", Json.obj("cursor" -> Json.Null),
                  id)) else unit[R]
            yield Left((next, if evs.nonEmpty || beat then now else quiet))
      }
    yield ()

/** THE GATEWAY'S MCP ENDPOINT (Streamable HTTP, `POST /mcp`): `initialize` (the events extension declared), the tool
 * `status` (/admin/status's JSON), `events/list`, `events/stream` */
object Mcp:
  def handles(req: Request): Boolean = req.path.takeWhile(_ != '?') == "/mcp"

  private def s(x: String): Json = Json.Str(x)
  private def reply(id: Json, result: Json): Json = Json.obj("jsonrpc" -> s("2.0"), "id" -> id, "result" -> result)
  private def failure(id: Json, code: Int, message: String): Json = Json.obj("jsonrpc" -> s("2.0"), "id" -> id,
    "error" -> Json.obj("code" -> Json.num(code), "message" -> s(message)))

  val statusTool: Json = Json.obj("name" -> s("status"),
    "description" -> s("The gateway's state: the model loaded, generations running, MLX's memory, the machine's room"),
    "inputSchema" -> Json.obj("type" -> s("object"), "properties" -> Json.obj()))

  def route[R[_]](req: Request, status: () => Json)(using In[Events.Gauge, R], In[Clock, R], In[Http, R])
      : Unit ! R =
    if req.method != "POST" then Http.respond[R](405, "text/plain", "POST JSON-RPC to /mcp")
    else
      val m = try Json.fromText(req.body) catch case _: Exception => Json.Null
      val id = m.field("id").getOrElse(Json.Null)
      val params = m.field("params").getOrElse(Json.obj())
      m.field("method").collect { case Json.Str(x) => x } match
        case Some("initialize") => Http.json[R](200, reply(id, Json.obj(
          "protocolVersion" -> params.field("protocolVersion").getOrElse(s("2025-06-18")),
          "capabilities" -> Json.obj("tools" -> Json.obj(), "extensions" -> Json.obj(Events.Extension -> Json.obj())),
          "serverInfo" -> Json.obj("name" -> s("okay-mlx"), "version" -> s("0.1")))))
        case Some(x) if x.startsWith("notifications/") => Http.respond[R](202, "text/plain", "")
        case Some("ping") => Http.json[R](200, reply(id, Json.obj()))
        case Some("tools/list") => Http.json[R](200, reply(id, Json.obj("tools" -> Json.arr(statusTool))))
        case Some("tools/call") => Http.json[R](200, reply(id, Json.obj("content" -> Json.arr(Json.obj(
          "type" -> s("text"), "text" -> s(status().render))))))
        case Some("events/list") =>
          Http.json[R](200, reply(id, Json.obj("resultType" -> s("complete"), "events" -> Events.descriptors)))
        case Some("events/stream") =>
          val name = params.field("name").collect { case Json.Str(x) => x }.getOrElse("")
          if !Events.names.contains(name) then
            Http.json[R](200, failure(id, -32602, s"no event type '$name': ${Events.names.mkString(", ")}"))
          else
            val min = params.field("arguments").flatMap(_.field("min_gb")).collect { case Json.Num(n) => n.toDouble }
              .getOrElse(0.0)
            Events.stream[R](Events.Sub(name, min), id)
        case Some(other) => Http.json[R](200, failure(id, -32601, s"Method not found: $other"))
        case None => Http.json[R](400, failure(id, -32600, "not a JSON-RPC request"))

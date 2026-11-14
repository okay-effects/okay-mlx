package okay.mlx

import okay.effects.json.Json
import okay.scala3.*
import okay.llm.{Http, Request}

/** THE GATEWAY MANAGED (the desktop app, a script): the model in memory and the machine's memory read, a model
 * loaded or loaded again, the memory given back — beside the APIs, on the same port, for 127.0.0.1 alone (the
 * server binds there).
 *
 *  - `GET /admin/status`: the model loaded (or none), the one loading, generations running, MLX's memory, the room the
 *    machine has and its pressure, the last generation's speeds, the self-unload's minutes;
 *  - `POST /admin/load {"model": "<repo>[+<adapter>]", "reload": false}`: that model in memory now (a switch waits for
 *    the generations running) — `reload` loads it again, its settings read anew;
 *  - `POST /admin/unload {"force": false}`: no model in memory (refused while a generation runs, unless `force`) */
object Admin:
  private def s(x: String): Json = Json.Str(x)
  private def n(x: Long): Json = Json.num(x)

  /** the client a request names itself as: its User-Agent's first product ("opencode/2.2.5 ai-sdk/…" → opencode,
   * "claude-cli/2.1 (external, cli)" → claude-cli) */
  def clientOf(req: Request): String =
    req.headers.get("user-agent").map(_.trim.takeWhile(c => c != ' ' && c != '/')).filter(_.nonEmpty).getOrElse("?")

  def handles(req: Request): Boolean = req.path.takeWhile(_ != '?').startsWith("/admin/")

  def route[R[_]](req: Request, sw: Switching)(using In[Http, R]): Unit ! R =
    def body: Json = try Json.fromText(if req.body.isBlank then "{}" else req.body) catch case _: Exception => Json.obj()
    def error(status: Int, message: String) = Http.json(status, Json.obj("error" -> s(message)))
    (req.method, req.path.takeWhile(_ != '?')) match
      case ("GET", "/admin/status") => Http.json(200, status(sw))
      case ("POST", "/admin/load") =>
        body.field("model").collect { case Json.Str(m) => m } match
          case None => error(400, "a model is wanted: {\"model\": \"<repo>\"}")
          case Some(m) =>
            sw.switchTo(m, body.field("reload").contains(Json.Bool(true))) match
              case Right(name) => Http.json(200, Json.obj("model" -> s(name)))
              case Left(why) => error(409, why)
      case ("POST", "/admin/unload") =>
        sw.unload(body.field("force").contains(Json.Bool(true))) match
          case Right(()) => Http.json(200, Json.obj("unloaded" -> Json.Bool(true)))
          case Left(why) => error(409, why)
      case (_, path) => error(404, path)

  def status(sw: Switching): Json =
    val st = sw.state
    val loaded = st.loaded.fold(Json.Null: Json)(l => Json.obj("model" -> s(l.model),
      "adapter" -> l.adapter.fold(Json.Null: Json)(s), "bytes" -> n(l.bytes), "mixture" -> Json.Bool(l.mixture),
      "expert_slots" -> n(l.slots), "since" -> n(l.since)))
    val last = st.lastTiming.fold(Json.Null: Json) { (t, at) =>
      Json.obj("prompt_tokens" -> n(t.promptTokens), "cached_tokens" -> n(t.cachedTokens),
        "prefill_ms" -> n(t.prefillNanos / 1000000), "tokens" -> n(t.tokens),
        "decode_per_second" -> Json.num(math.round(t.decodePerSecond * 10) / 10.0), "at" -> n(at)) }
    Json.obj("loaded" -> loaded, "last_model" -> s(st.last),
      "loading" -> st.loading.fold(Json.Null: Json)(s), "switching" -> Json.Bool(st.switching),
      "running" -> n(st.going.size), "generations" -> Json.Arr(st.going.map(g => Json.obj("model" -> s(g.model),
        "client" -> s(g.client), "prompt_tokens" -> n(g.prompt), "cached_tokens" -> n(g.cached),
        "tokens" -> n(g.tokens), "millis" -> n(g.millis),
        "per_second" -> Json.num(math.round(g.perSecond * 10) / 10.0)))),
      "mlx_active_bytes" -> n(st.held), "idle_seconds" -> n(st.idleSeconds),
      "memory_room_bytes" -> n(Memory.room), "memory_pressure" -> n(Memory.pressure),
      "unload_after_minutes" -> n(Settings.unloadAfter), "last_generation" -> last)

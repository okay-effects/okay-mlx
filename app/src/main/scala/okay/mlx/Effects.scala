package okay.mlx

import java.nio.file.{Files as NioFiles, Path}
import scala.collection.mutable
import okay.scala3.*
import mlx.llm.*

/** what is asked of a model: a conversation (messages as a chat template takes them), the tools it may call */
final case class Ask(messages: Vector[Json], tools: Vector[Json] = Vector.empty, maxTokens: Int = 1024,
    thinking: Boolean = false)

/** a generation going on */
final case class Gen(id: Long)

/** a generation done: its turn read, what it measured, whether the model ended it (else: the limit) */
final case class Finished(reply: Reply, timing: Timing, byStop: Boolean)

/** THE LANGUAGE MODEL, as the app sees it: a generation started, its text piece by piece, its end; which model and
 * on what is the handler's */
enum Llm[X]:
  case Name() extends Llm[String]
  case Count(ask: Ask) extends Llm[Int]
  case Start(ask: Ask) extends Llm[Gen]
  case Next(gen: Gen) extends Llm[Option[String]]
  case Finish(gen: Gen) extends Llm[Finished]

object Llm:
  def name[R[_]](using In[Llm, R]): String ! R = perform[Llm](Name())
  def count[R[_]](ask: Ask)(using In[Llm, R]): Int ! R = perform[Llm](Count(ask))
  def start[R[_]](ask: Ask)(using In[Llm, R]): Gen ! R = perform[Llm](Start(ask))
  /** the next piece of text, or none: the generation is over */
  def next[R[_]](gen: Gen)(using In[Llm, R]): Option[String] ! R = perform[Llm](Next(gen))
  def finish[R[_]](gen: Gen)(using In[Llm, R]): Finished ! R = perform[Llm](Finish(gen))

  /** a generation to its end */
  def complete[R[_]](ask: Ask)(using In[Llm, R]): Finished ! R =
    for
      g <- start(ask)
      _ <- loop[Unit, Unit, R](())(_ => next(g).map(p => if p.isDefined then Left(()) else Right(())))
      f <- finish(g)
    yield f

  /** a model on MLX: its chat's template makes the prompt, `enable_thinking` as asked; greedy */
  def mlx[R[_], Rest[_], A](name: String, model: Model, chat: Chat)(p: A ! R)(using Split[Llm, R, Rest]): A ! Rest =
    final class Running(val session: Session, val ask: Ask):
      val stream = chat.tokenizer.Stream()
      val text = new java.lang.StringBuilder
    val running = mutable.HashMap.empty[Long, Running]
    var ids = 0L
    def prompt(ask: Ask) = chat.prompt(ask.messages, ask.tools, Map("enable_thinking" -> ask.thinking))
    handle(p, Handler.tail[Llm, Rest, A, A](pure)([X] => (op: Llm[X]) => op match
      case Name() => name
      case Count(ask) => prompt(ask).length
      case Start(ask) =>
        ids += 1
        running(ids) = Running(Session(model, prompt(ask), ask.maxTokens, chat.stops), ask)
        Gen(ids)
      case Next(gen) =>
        val r = running(gen.id)
        r.session.next().map { t =>
          val piece = r.stream.push(t)
          r.text.append(piece)
          piece
        }
      case Finish(gen) =>
        val r = running.remove(gen.id).get
        r.session.close()
        Finished(Reply.parse(r.text.toString, r.ask.thinking, r.ask.tools), r.session.timing, r.session.endedByStop)))

  /** answers given by a function of the last message's text, piece by piece (by word), timings made up: the app's
   * logic without a GPU */
  /** the text in pieces a word each, its space kept after it (no look-behind: Scala Native's regex is RE2's) */
  private def words(s: String): List[String] =
    val out = List.newBuilder[String]
    var from = 0
    for i <- s.indices if s.charAt(i) == ' ' do { out += s.substring(from, i + 1); from = i + 1 }
    if from < s.length then out += s.substring(from)
    out.result()

  def fake[R[_], Rest[_], A](answer: String => String)(p: A ! R)(using Split[Llm, R, Rest]): A ! Rest =
    val running = mutable.HashMap.empty[Long, (Ask, List[String], StringBuilder)]
    var ids = 0L
    def lastText(ask: Ask) = ask.messages.lastOption.map(_("content")).collect { case Json.Str(s) => s }.getOrElse("")
    handle(p, Handler.tail[Llm, Rest, A, A](pure)([X] => (op: Llm[X]) => op match
      case Name() => "fake"
      case Count(ask) => ask.messages.map(m => lastText(Ask(Vector(m))).length / 4 + 4).sum
      case Start(ask) =>
        ids += 1
        running(ids) = (ask, words(answer(lastText(ask))), StringBuilder())
        Gen(ids)
      case Next(gen) =>
        val (ask, rest, text) = running(gen.id)
        rest match
          case piece :: more => running(gen.id) = (ask, more, text.append(piece)); Some(piece)
          case Nil => None
      case Finish(gen) =>
        val (ask, _, text) = running.remove(gen.id).get
        val n = text.length / 4 + 1
        Finished(Reply.parse(text.toString, ask.thinking, ask.tools), Timing(10, 1_000_000L, n, n * 10_000_000L),
          byStop = true)))

/** FILES: a model's snapshot in the HuggingFace cache, a text read */
enum Files[X]:
  case Snapshot(repo: String) extends Files[Option[Path]]
  case Read(path: Path) extends Files[String]

object Files:
  def snapshot[R[_]](repo: String)(using In[Files, R]): Option[Path] ! R = perform[Files](Snapshot(repo))
  def read[R[_]](path: Path)(using In[Files, R]): String ! R = perform[Files](Read(path))

  /** the disk: the HuggingFace cache where HF_HOME / HF_HUB_CACHE say, else ~/.cache/huggingface/hub */
  def disk[R[_], Rest[_], A](p: A ! R)(using Split[Files, R, Rest]): A ! Rest =
    handle(p, Handler.tail[Files, Rest, A, A](pure)([X] => (op: Files[X]) => op match
      case Snapshot(repo) => Models.snapshot(repo)
      case Read(path) => NioFiles.readString(path)))

/** THE CONSOLE: a line out */
enum Console[X]:
  case Line(text: String) extends Console[Unit]

object Console:
  def line[R[_]](text: String)(using In[Console, R]): Unit ! R = perform[Console](Line(text))

  def stdout[R[_], Rest[_], A](p: A ! R)(using Split[Console, R, Rest]): A ! Rest =
    handle(p, Handler.tail[Console, Rest, A, A](pure)([X] => (op: Console[X]) => op match
      case Line(text) => println(text)))

  /** the lines, in order, and the value */
  def collect[R[_], Rest[_], A](p: A ! R)(using Split[Console, R, Rest]): (Vector[String], A) ! Rest =
    handle(p, Handler.stateful[Console, Rest, A, (Vector[String], A), Vector[String]](Vector.empty)(
      (lines, a) => pure((lines, a)))(
      [X] => (op: Console[X], cell: Cell[Vector[String]]) => op match
        case Line(text) => cell.set(cell.get :+ text)))

/** AN HTTP REQUEST, read */
final case class Request(method: String, path: String, headers: Map[String, String], body: String)

/** AN HTTP RESPONSE, as the program makes it: whole, or streamed — opened, sent piece by piece, closed */
enum Http[X]:
  case Respond(status: Int, contentType: String, body: String) extends Http[Unit]
  case Open(status: Int, contentType: String) extends Http[Unit]
  case Send(chunk: String) extends Http[Unit]
  case Close() extends Http[Unit]

object Http:
  def respond[R[_]](status: Int, contentType: String, body: String)(using In[Http, R]): Unit ! R =
    perform[Http](Respond(status, contentType, body))
  def json[R[_]](status: Int, body: Json)(using In[Http, R]): Unit ! R =
    respond(status, "application/json", body.render)
  def open[R[_]](status: Int, contentType: String)(using In[Http, R]): Unit ! R =
    perform[Http](Open(status, contentType))
  def send[R[_]](chunk: String)(using In[Http, R]): Unit ! R = perform[Http](Send(chunk))
  def close[R[_]](using In[Http, R]): Unit ! R = perform[Http](Close())

  private def reason(status: Int) = status match
    case 200 => "OK"; case 400 => "Bad Request"; case 404 => "Not Found"; case 500 => "Internal Server Error"
    case _ => "Status"

  /** to a socket's stream: a whole response with its length; a streamed one closed by closing the connection */
  def socket[R[_], Rest[_], A](out: java.io.OutputStream)(p: A ! R)(using Split[Http, R, Rest]): A ! Rest =
    def head(status: Int, contentType: String, extra: String) =
      out.write((s"HTTP/1.1 $status ${reason(status)}\r\nContent-Type: $contentType\r\n$extra" +
        "Connection: close\r\n\r\n").getBytes("UTF-8"))
    handle(p, Handler.tail[Http, Rest, A, A](pure)([X] => (op: Http[X]) => op match
      case Respond(status, contentType, body) =>
        val bytes = body.getBytes("UTF-8")
        head(status, contentType, s"Content-Length: ${bytes.length}\r\n")
        out.write(bytes)
        out.flush()
      case Open(status, contentType) =>
        head(status, contentType, "Cache-Control: no-cache\r\n")
        out.flush()
      case Send(chunk) =>
        out.write(chunk.getBytes("UTF-8"))
        out.flush()
      case Close() => out.flush()))

  /** what was sent: the status, the content type, the body (pieces joined) */
  def collect[R[_], Rest[_], A](p: A ! R)(using Split[Http, R, Rest]): ((Int, String, String), A) ! Rest =
    handle(p, Handler.stateful[Http, Rest, A, ((Int, String, String), A), (Int, String, String)]((0, "", ""))(
      (r, a) => pure((r, a)))(
      [X] => (op: Http[X], cell: Cell[(Int, String, String)]) => op match
        case Respond(status, contentType, body) => cell.set((status, contentType, body))
        case Open(status, contentType) => cell.set((status, contentType, ""))
        case Send(chunk) => val (s, c, b) = cell.get; cell.set((s, c, b + chunk))
        case Close() => ()))

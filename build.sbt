// okay-mlx: okay-llm's model on Apple's MLX — mlx-scala as an `Llm.Backend`; and the app: ask, bench, serve (the
// gateway). okay-llm has the effects, the gateway, the server; this module the hardware
import sbtcrossproject.CrossPlugin.autoImport.{crossProject, CrossType}
import scala.scalanative.build.*

ThisBuild / scalaVersion := "3.3.8"
ThisBuild / organization := "io.github.okay-effects"
ThisBuild / version := "0.1.1-SNAPSHOT"
ThisBuild / scalacOptions ++= Seq("-deprecation", "-feature", "-unchecked", "-Wunused:imports,privates,locals")
ThisBuild / resolvers ++= Seq("mlx-scala" at "https://sergey-scherbina.github.io/mlx-scala/maven",
  "okay-llm" at "https://okay-effects.github.io/okay-llm/maven",
  "okay-scala" at "https://okay-effects.github.io/okay-scala/maven",
  "okay-simple" at "https://okay-effects.github.io/okay-simple/maven")
ThisBuild / licenses := List("Apache-2.0" -> url("https://www.apache.org/licenses/LICENSE-2.0.txt"))
ThisBuild / homepage := Some(url("https://github.com/okay-effects/okay-mlx"))
ThisBuild / developers := List(Developer("sergey-scherbina", "Sergiy Shcherbyna", "sergey.scherbina@gmail.com",
  url("https://github.com/sergey-scherbina")))
ThisBuild / scmInfo := Some(ScmInfo(url("https://github.com/okay-effects/okay-mlx"),
  "scm:git@github.com:okay-effects/okay-mlx.git"))
ThisBuild / versionScheme := Some("early-semver")

/** RELEASES, ON GITHUB PAGES: `sbt publish` writes the Maven repository into target/pages-maven, which goes to the
 * gh-pages branch under maven/ — https://okay-effects.github.io/okay-mlx/maven */
val pagesRepository = settingKey[File]("the Maven repository a release is written to, for GitHub Pages")
ThisBuild / pagesRepository := (ThisBuild / baseDirectory).value / "target" / "pages-maven"
ThisBuild / publishTo := Some(MavenCache("pages", (ThisBuild / pagesRepository).value))
ThisBuild / Compile / packageDoc / publishArtifact := false

/** mlx-scala's native libraries (its native-lib/build.sh): MLX_SCALA_LIB, else ../mlx-scala/native-lib/out/lib */
val nativeLib = sys.env.get("MLX_SCALA_LIB").map(file).getOrElse(file("../mlx-scala/native-lib/out/lib"))
  .getAbsoluteFile
val mlxScala = "0.1.0"

val jvmNative = Seq(
  Test / fork := true,
  run / fork := true,
  javaOptions ++= Seq("--enable-native-access=ALL-UNNAMED", s"-Dokm.lib=$nativeLib/libokm.dylib", "-Xss16m"),
  run / connectInput := true)
val nativeLinking = Seq(
  nativeConfig ~= (_.withMode(Mode.releaseFast).withLTO(LTO.none).withEmbedResources(true)
    .withLinkingOptions(Seq(s"-L$nativeLib", "-lmlxc", s"-Wl,-rpath,$nativeLib"))))

/** THE APP: generation and its measurement — `sbt "appJVM/run ask <question>"`, `sbt "appNative/run bench 3"` */
lazy val app = crossProject(JVMPlatform, NativePlatform).crossType(CrossType.Pure).in(file("app"))
  .settings(name := "okay-mlx",
    libraryDependencies ++= Seq("io.github.sergey-scherbina" %%% "mlx-scala-llm" % mlxScala,
      "io.github.okay-effects" %%% "okay-llm" % "0.1.0",
      "io.github.okay-effects" %%% "okay-effects-json-value" % "0.1.1",
      "org.scalameta" %%% "munit" % "1.2.3" % Test))
  .jvmSettings(jvmNative)
  .nativeSettings(nativeLinking)

lazy val root = (project in file(".")).aggregate(app.componentProjects.map(p => p: ProjectReference): _*)
  .settings(publish / skip := true)

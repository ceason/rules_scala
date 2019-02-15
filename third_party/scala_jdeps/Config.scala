package third_party.scala_jdeps

import java.io.File

import scala.collection.mutable
import scala.util.Try


/**
  *
  */
class Config(args: List[String]) {

  import Config._

  var directJars: mutable.Set[String] = mutable.HashSet()
  var ignoredJars: mutable.Set[String] = mutable.HashSet()
  val classpathJars: mutable.Set[String] = mutable.HashSet()
  var output: String = _
  var strictDeps: EnforcementMode = EnforcementMode.Off
  var unusedDeps: EnforcementMode = EnforcementMode.Off
  var currentTarget: String = _
  for (option <- args) {
    option.split(":", 2).toList match {
      case "direct-jars" :: paths :: _ => directJars ++= paths.split(File.pathSeparator)
      case "classpath-jars" :: paths :: _ => classpathJars ++= paths.split(File.pathSeparator)
      case "ignored-jars" :: paths :: _ => ignoredJars ++= paths.split(File.pathSeparator)
      case "output" :: path :: _ => output = path
      case "current-target" :: target :: _ => currentTarget = target
      case "strict-deps-mode" :: mode :: _ => strictDeps = EnforcementMode.parse(mode)
      case "unused-deps-mode" :: mode :: _ => unusedDeps = EnforcementMode.parse(mode)
      case unknown :: _ => sys.error(s"unknown param $unknown")
      case Nil =>
    }
  }
  require(output != null, "Must provide '-P:scala-jdeps:output:<outputPath>' arg")
  require(currentTarget != null, "Must provide '-P:scala-jdeps:current-target:<targetLabel>' arg")

  var directLabels: Set[String] = directJars.toSet.flatMap { path: String =>
    Try(ScalaJdeps.getTargetFromJar(path)).toOption
  }
  var ignoredLabels: Set[String] = ignoredJars.toSet.flatMap { path: String =>
    Try(ScalaJdeps.getTargetFromJar(path)).toOption
  }
}

object Config {

  sealed trait EnforcementMode

  object EnforcementMode {

    case object Error extends EnforcementMode

    case object Warn extends EnforcementMode

    case object Off extends EnforcementMode

    def parse(mode: String): EnforcementMode = mode.toLowerCase match {
      case "error" => Error
      case "warn" => Warn
      case "off" => Off
      case _ => sys.error(
        s"unknown enforcement mode '$mode' expected one of 'error,warn,off'")
    }
  }

}

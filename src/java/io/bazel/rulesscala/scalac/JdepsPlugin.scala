package io.bazel.rulesscala.scalac

import java.io.{File, FileOutputStream}

import com.google.devtools.build.lib.view.proto.Deps.{Dependencies, Dependency}
import io.bazel.rulesscala.scalac.JdepsEnforcer.EnforcementMode
import io.bazel.rulesscala.scalac.JdepsPlugin._

import scala.collection.JavaConverters._
import scala.collection.mutable
import scala.tools.nsc.plugins.{Plugin, PluginComponent}
import scala.tools.nsc.{Global, Phase}

class JdepsPlugin(val global: Global) extends Plugin {
  self =>
  val name = "scala-jdeps"
  val description = "Outputs bazel jdeps. Can also do dependency enforcement."

  val components: List[PluginComponent] = List[PluginComponent](Component)

  implicit var cfg: Config = _

  override def init(options: List[String], error: String => Unit): Boolean = {
    try cfg = new Config(options) catch {
      case e: RuntimeException =>
        error(s"couldn't initialize scala-jdeps config: ${e.getMessage}")
        return false
    }
    true
  }

  private object Component extends PluginComponent {
    implicit val global: Global = self.global

    import global._

    override val runsAfter = List("jvm")

    val phaseName: String = self.name

    override def newPhase(prev: Phase): StdPhase = new StdPhase(prev) {
      override def run(): Unit = {
        super.run()
        val usedJars = findUsedJars.intersect(cfg.classpathJars)
        val jdeps = buildJdeps(usedJars)
        // enforce strict/unused deps as appropriate
        val enforcer = new JdepsEnforcer(jdeps, cfg.enforcerArgs.asJava)
        if (enforcer.strictDeps != EnforcementMode.OFF) {
          for (msg <- enforcer.getViolatingStrictDeps) {
            enforcer.strictDeps match {
              case EnforcementMode.ERROR => reporter.error(NoPosition, msg)
              case EnforcementMode.WARN => reporter.warning(NoPosition, msg)
            }
          }
        }
        if (enforcer.unusedDeps != EnforcementMode.OFF) {
          for (msg <- enforcer.getViolatingUnusedDeps) {
            enforcer.unusedDeps match {
              case EnforcementMode.ERROR => reporter.error(NoPosition, msg)
              case EnforcementMode.WARN => reporter.warning(NoPosition, msg)
            }
          }
        }

        // write out jdeps file
        val jdepsFile = new FileOutputStream(cfg.output)
        jdeps.writeTo(jdepsFile)
        jdepsFile.close()
      }

      override def apply(unit: global.CompilationUnit): Unit = ()
    }
  }

}

object JdepsPlugin {

  class Config(args: List[String]) {
    var output: String = _
    var currentTarget: String = _
    val classpathJars: mutable.Set[String] = mutable.HashSet()
    val enforcerArgs: mutable.MutableList[String] = mutable.MutableList()
    for (arg <- args) {
      arg.split(":", 2).toList match {
        case "output" :: path :: _ => output = path
        case "current-target" :: target :: _ => currentTarget = target
        case "classpath-jars" :: paths :: _ => classpathJars ++= paths.split(File.pathSeparator)
        // pass dep enforcer args through
        case "dep_enforcer" :: deArgs :: _ => deArgs.split(":", 2).toList match {
          case flag :: value :: Nil => enforcerArgs += (s"--$flag", value)
          case _ => sys.error(s"Bad arg to dep_enforcer '$deArgs'")
        }
        case unknown :: _ => sys.error(s"unknown param $unknown")
        case Nil =>
      }
    }
    require(output != null, "Must provide '-P:scala-jdeps:output:<outputPath>' arg")
    require(currentTarget != null, "Must provide '-P:scala-jdeps:current-target:<targetLabel>' arg")
  }

  def buildJdeps(usedJars: Set[String])(implicit c: Config): Dependencies = {
    val deps = Dependencies.newBuilder()
      .setRuleLabel(c.currentTarget)
      .setSuccess(true)
    for (jar <- c.classpathJars.toList.sorted) {
      val kind = if (usedJars.contains(jar)) {
        Dependency.Kind.EXPLICIT
      } else {
        Dependency.Kind.IMPLICIT
      }
      deps.addDependency(Dependency.newBuilder()
        .setPath(jar)
        .setKind(kind)
        .build())
    }
    deps.build()
  }

  def findUsedJars(implicit global: Global): Set[String] = {
    import global._
    val jars = collection.mutable.Set[String]()

    def walkTopLevels(root: Symbol): Unit = {
      def safeInfo(sym: Symbol): Type =
        if (sym.hasRawInfo && sym.rawInfo.isComplete) sym.info else NoType

      def packageClassOrSelf(sym: Symbol): Symbol =
        if (sym.hasPackageFlag && !sym.isModuleClass) sym.moduleClass else sym

      for (x <- safeInfo(packageClassOrSelf(root)).decls) {
        if (x == root) ()
        else if (x.hasPackageFlag) walkTopLevels(x)
        else if (x.owner != root) { // exclude package class members
          if (x.hasRawInfo && x.rawInfo.isComplete) {
            val assocFile = x.associatedFile
            if (assocFile.path.endsWith(".class") && assocFile.underlyingSource.isDefined)
              assocFile.underlyingSource.foreach(jars += _.path)
          }
        }
      }
    }

    exitingTyper {
      walkTopLevels(RootClass)
    }
    jars.toSet
  }

}
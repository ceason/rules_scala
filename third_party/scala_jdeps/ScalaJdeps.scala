package third_party.scala_jdeps

import java.io.FileOutputStream
import java.util.jar.JarFile

import com.google.devtools.build.lib.view.proto.Deps.{Dependencies, Dependency}
import third_party.scala_jdeps.Config.EnforcementMode
import third_party.scala_jdeps.ScalaJdeps._

import scala.tools.nsc.plugins.{Plugin, PluginComponent}
import scala.tools.nsc.{Global, Phase}

class ScalaJdeps(val global: Global) extends Plugin {
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

    override val runsAfter = List("jvm")

    val phaseName: String = self.name

    override def newPhase(prev: Phase): StdPhase = new StdPhase(prev) {
      override def run(): Unit = {
        super.run()
        val usedJars = findUsedJars
        enforceUnusedDeps(usedJars)
        enforceStrictDeps(usedJars)
        val jdeps = buildJdeps(usedJars)
        val jdepsFile = new FileOutputStream(cfg.output)
        jdeps.writeTo(jdepsFile)
        jdepsFile.close()
      }

      override def apply(unit: global.CompilationUnit): Unit = ()
    }
  }

}

object ScalaJdeps {

  def buildJdeps(usedJars: Set[String])(implicit c: Config): Dependencies = {
    val deps = Dependencies.newBuilder()
      .setRuleLabel(c.currentTarget)
      .setSuccess(true)
    for (jar <- c.classpathJars.toList.sorted) {
      val kind = if (!usedJars.contains(jar)) {
        Dependency.Kind.UNUSED
      } else if (c.directJars.contains(jar)) {
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

  def enforceUnusedDeps(usedJars: Set[String])(implicit g: Global, c: Config): Unit = {
    if (c.unusedDeps == EnforcementMode.Off) {
      return
    }
    c.directJars
      .filterNot(usedJars.contains)
      .filterNot(c.ignoredJars.contains)
      .filter(c.classpathJars.contains)
      .map(getTargetFromJar)
      .map { target =>
        s"""Target '$target' is specified as a dependency to ${c.currentTarget} but isn't used, please remove it from the deps.
           |You can use the following buildozer command:
           |buildozer 'remove deps $target' ${c.currentTarget}
           |""".stripMargin
      }.foreach { errMsg =>
      c.unusedDeps match {
        case EnforcementMode.Error => g.reporter.error(g.NoPosition, errMsg)
        case EnforcementMode.Warn => g.reporter.warning(g.NoPosition, errMsg)
        case _ =>
      }
    }
  }

  def enforceStrictDeps(usedJars: Set[String])(implicit g: Global, c: Config): Unit = {
    if (c.strictDeps == EnforcementMode.Off) {
      return
    }
    usedJars.toSeq
      .filterNot(c.directJars.contains)
      .filterNot(c.ignoredJars.contains)
      .filter(c.classpathJars.contains)
      .map(getTargetFromJar)
      .map { target =>
        s"""Target '$target' is used but isn't explicitly declared, please add it to the deps.
           |You can use the following buildozer command:
           |buildozer 'add deps $target' ${c.currentTarget}""".stripMargin
      }.foreach { errMsg =>
      c.unusedDeps match {
        case EnforcementMode.Error => g.reporter.error(g.NoPosition, errMsg)
        case EnforcementMode.Warn => g.reporter.warning(g.NoPosition, errMsg)
        case _ =>
      }
    }
  }

  private def getTargetFromJar(jarPath: String): String = {
    // extract target label from jar
    val jar = new JarFile(jarPath)
    val targetLabel = Option(jar.getManifest
      .getMainAttributes
      .getValue("Target-Label"))
    jar.close()
    // just default to the jar path if we couldn't find the label
    targetLabel.getOrElse(jarPath)
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

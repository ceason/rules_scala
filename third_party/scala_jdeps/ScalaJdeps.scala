package third_party.scala_jdeps

import java.io.{FileInputStream, FileOutputStream}

import com.google.devtools.build.lib.view.proto.Deps.{Dependencies, Dependency}
import rules_scala.compileoptions.CompileOptionsOuterClass.CompileOptions
import rules_scala.compileoptions.CompileOptionsOuterClass.CompileOptions.EnforcementMode
import third_party.scala_jdeps.ScalaJdeps._

import scala.collection.JavaConverters._
import scala.reflect.io.AbstractFile
import scala.tools.nsc.plugins.{Plugin, PluginComponent}
import scala.tools.nsc.{Global, Phase}

class ScalaJdeps(val global: Global) extends Plugin {
  self =>
  val name = "scala-jdeps"
  val description = "Outputs bazel jdeps. Can also do dependency enforcement."

  val components: List[PluginComponent] = List[PluginComponent](Component)

  var opts: CompileOptions = _

  override def init(options: List[String], error: (String) => Unit): Boolean = {
    for (option <- options) {
      option.split(":").toList match {
        case "compile-options" :: path :: Nil =>
          val f = new FileInputStream(path)
          opts = CompileOptions.parseFrom(f)
          f.close()
        case unknown :: _ =>
          error(s"unknown param $unknown")
        case Nil =>
      }
    }
    opts != null || {
      error(s"CompileOptions failed to initialize. Are you sure you provided the 'compile-options' plugin arg?")
      false
    }
  }


  private object Component extends PluginComponent {
    val global: Global = self.global

    import global._

    override val runsAfter = List("jvm")

    val phaseName: String = self.name

    override def newPhase(prev: Phase): StdPhase = new StdPhase(prev) {
      override def run(): Unit = {
        super.run()

        val usedJars = findUsedJars(global).map(_.path)

        for (message <- enforceUnusedDeps(opts, usedJars)) {
          opts.getUnusedDepsMode match {
            case EnforcementMode.WARN => reporter.warning(NoPosition, message)
            case EnforcementMode.ERROR => reporter.error(NoPosition, message)
            case _ =>
          }
        }

        for (message <- enforceStrictDeps(opts, usedJars)) {
          opts.getStrictDepsMode match {
            case EnforcementMode.WARN => reporter.warning(NoPosition, message)
            case EnforcementMode.ERROR => reporter.error(NoPosition, message)
            case _ =>
          }
        }

        val jdeps = buildJdeps(opts, usedJars)
        val jdepsFile = new FileOutputStream(opts.getJdepsOutput)
        jdeps.writeTo(jdepsFile)
        jdepsFile.close()
      }

      override def apply(unit: CompilationUnit): Unit = ()
    }
  }

}


object ScalaJdeps {

  def buildJdeps(o: CompileOptions, usedJars: Set[String]): Dependencies = {
    val deps = Dependencies.newBuilder()
      .setRuleLabel(o.getCurrentTarget)
      .setSuccess(true)
    val directJars = o.getDirectJarsList.asScala.toSet
    for (jar <- o.getClasspathJarsList.asScala) {
      val kind = if (!usedJars.contains(jar)) {
        Dependency.Kind.UNUSED
      } else if (directJars.contains(jar)) {
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

  def enforceUnusedDeps(o: CompileOptions, usedJars: Set[String]): Seq[String] = {
    if (o.getUnusedDepsMode == EnforcementMode.OFF) {
      return Nil
    }
    val ignoredJars = o.getUnusedDepsIgnoredJarsList.asScala.toSet
    o.getDirectJarsList.asScala
      .filterNot(usedJars.contains)
      .filterNot(ignoredJars.contains)
      .map(getTargetFromJar)
      .map { target =>
        s"""Target '$target' is specified as a dependency to ${o.getCurrentTarget} but isn't used, please remove it from the deps.
           |You can use the following buildozer command:
           |buildozer 'remove deps $target' ${o.getCurrentTarget}
           |""".stripMargin
      }
  }

  def enforceStrictDeps(o: CompileOptions, usedJars: Set[String]): Seq[String] = {
    if (o.getStrictDepsMode == EnforcementMode.OFF) {
      return Nil
    }
    val ignoredJars = o.getStrictDepsIgnoredJarsList.asScala.toSet
    val directJars = o.getDirectJarsList.asScala.toSet
    usedJars.toSeq
      .filterNot(directJars.contains)
      .filterNot(ignoredJars.contains)
      .map(getTargetFromJar)
      .map { target =>
        s"""Target '$target' is used but isn't explicitly declared, please add it to the deps.
           |You can use the following buildozer command:
           |buildozer 'add deps $target' ${o.getCurrentTarget}""".stripMargin
      }
  }

  private def getTargetFromJar(jarPath: String): String = {
    // TODO: extract target label from jar
    jarPath
  }

  def findUsedJars(global: Global): Set[AbstractFile] = {
    import global._
    val jars = collection.mutable.Set[AbstractFile]()

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
              assocFile.underlyingSource.foreach(jars += _)
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

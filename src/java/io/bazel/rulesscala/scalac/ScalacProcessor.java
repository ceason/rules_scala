package io.bazel.rulesscala.scalac;

import io.bazel.rulesscala.jar.JarCreator;
import io.bazel.rulesscala.worker.GenericWorker;
import io.bazel.rulesscala.worker.Processor;
import java.io.File;
import java.io.FileInputStream;
import java.io.FileNotFoundException;
import java.io.FileOutputStream;
import java.io.IOException;
import java.io.InputStream;
import java.io.OutputStream;
import java.lang.reflect.Field;
import java.nio.file.FileSystems;
import java.nio.file.FileVisitResult;
import java.nio.file.Files;
import java.nio.file.Path;
import java.nio.file.Paths;
import java.nio.file.SimpleFileVisitor;
import java.nio.file.attribute.BasicFileAttributes;
import java.util.ArrayList;
import java.util.Arrays;
import java.util.Enumeration;
import java.util.List;
import java.util.Map;
import java.util.Map.Entry;
import java.util.jar.JarEntry;
import java.util.jar.JarFile;
import org.apache.commons.io.IOUtils;
import rules_scala.compileoptions.CompileOptionsOuterClass.CompileOptions;
import rules_scala.compileoptions.CompileOptionsOuterClass.CompileOptions.Resource;
import scala.tools.nsc.Driver;
import scala.tools.nsc.MainClass;
import scala.tools.nsc.reporters.ConsoleReporter;

/*
TODO:
  wire up new (proto message based) CompileOptions
 */

class ScalacProcessor implements Processor {
  /** This is the reporter field for scalac, which we want to access */
  private static Field reporterField;

  static {
    try {
      reporterField = Driver.class.getDeclaredField("reporter"); // NoSuchFieldException
      reporterField.setAccessible(true);
    } catch (NoSuchFieldException ex) {
      throw new RuntimeException("could not access reporter field on Driver", ex);
    }
  }

  @Override
  public void processRequest(List<String> args) throws Exception {
    Path tmpPath = null;
    if (args.size() != 1) {
      String msg = String
          .format("Expected exactly one argument (path to compile options file) but got %d:\n  %s",
              args.size(), String.join("\n  ", args));
      throw new IllegalArgumentException(msg);
    }
    String opsFile = args.get(0);
    try (FileInputStream f = new FileInputStream(opsFile)) {

      CompileOptions ops = CompileOptions.parseFrom(f);
      Path outputPath = FileSystems.getDefault().getPath(ops.getJarOutput());
      tmpPath = Files.createTempDirectory(outputPath.getParent(), "tmp");

      List<File> jarFiles = extractSourceJars(ops, outputPath.getParent());
      List<File> scalaJarFiles = filterFilesByExtension(jarFiles, ".scala");
      List<File> javaJarFiles = filterFilesByExtension(jarFiles, ".java");

      if (!ops.getExpectJavaOutput() && !javaJarFiles.isEmpty()) {
        throw new RuntimeException(
            "Found java files in source jars but expect Java output is set to false");
      }

      String[] scalaSources = collectSrcJarSources(ops.getFilesList().toArray(new String[0]), scalaJarFiles, javaJarFiles);
//      List<String> scalaSources2 = new ArrayList<String>();
//      scalaSources2.addAll(ops.getFilesList());
//      scalaSources2.addAll(scalaJarFiles);
//      scalaSources2.addAll(javaJarFiles)

      String[] javaSources = GenericWorker.appendToString(ops.getJavaFilesList().toArray(new String[0]), javaJarFiles);
      if (scalaSources.length == 0 && javaSources.length == 0) {
        throw new RuntimeException("Must have input files from either source jars or local files.");
      }

      /**
       * Compile scala sources if available (if there are none, we will simply compile java
       * sources).
       */
      if (scalaSources.length > 0) {
        compileScalaSources(ops, scalaSources, opsFile, tmpPath);
      }

      /** Copy the resources */
      copyResources(ops.getResourceFilesMap(), ops.getResourceStripPrefix(), tmpPath);

      /** Extract and copy resources from resource jars */
      copyResourceJars(ops.getResourceJarsList().toArray(new String[0]), tmpPath);

      /** Copy classpath resources to root of jar */
      copyClasspathResourcesToRoot(ops.getClasspathResourceFilesList().toArray(new String[0]), tmpPath);

      /** Now build the output jar */
      String[] jarCreatorArgs = {"-m", ops.getManifest(), outputPath.toString(), tmpPath.toString()};
      JarCreator.main(jarCreatorArgs);
    } finally {
      removeTmp(tmpPath);
    }
  }

  private static String[] collectSrcJarSources(
      String[] files, List<File> scalaJarFiles, List<File> javaJarFiles) {
    String[] scalaSources = GenericWorker.appendToString(files, scalaJarFiles);
    return GenericWorker.appendToString(scalaSources, javaJarFiles);
  }

  private static List<File> filterFilesByExtension(List<File> files, String extension) {
    List<File> filtered = new ArrayList<File>();
    for (File f : files) {
      if (f.toString().endsWith(extension)) {
        filtered.add(f);
      }
    }
    return filtered;
  }

  private static String[] sourceExtensions = {".scala", ".java"};

  private static List<File> extractSourceJars(CompileOptions opts, Path tmpParent)
      throws IOException {
    List<File> sourceFiles = new ArrayList<File>();

    for (String jarPath : opts.getSourceJarsList()) {
      if (jarPath.length() > 0) {
        Path tmpPath = Files.createTempDirectory(tmpParent, "tmp");
        sourceFiles.addAll(extractJar(jarPath, tmpPath.toString(), sourceExtensions));
      }
    }

    return sourceFiles;
  }

  private static List<File> extractJar(String jarPath, String outputFolder, String[] extensions)
      throws IOException, FileNotFoundException {

    List<File> outputPaths = new ArrayList<File>();
    JarFile jar = new JarFile(jarPath);
    Enumeration<JarEntry> e = jar.entries();
    while (e.hasMoreElements()) {
      JarEntry file = e.nextElement();
      String thisFileName = file.getName();
      // we don't bother to extract non-scala/java sources (skip manifest)
      if (extensions != null && !matchesFileExtensions(thisFileName, extensions)) continue;
      File f = new File(outputFolder + File.separator + file.getName());

      if (file.isDirectory()) { // if its a directory, create it
        f.mkdirs();
        continue;
      }

      File parent = f.getParentFile();
      parent.mkdirs();
      outputPaths.add(f);

      InputStream is = jar.getInputStream(file); // get the input stream
      OutputStream fos = new FileOutputStream(f);
      IOUtils.copy(is, fos);
      fos.close();
      is.close();
    }
    return outputPaths;
  }

  private static boolean matchesFileExtensions(String fileName, String[] extensions) {
    for (String e : extensions) {
      if (fileName.endsWith(e)) {
        return true;
      }
    }
    return false;
  }

  private static String[] encodeBazelTargets(String[] targets) {
    return Arrays.stream(targets).map(ScalacProcessor::encodeBazelTarget).toArray(String[]::new);
  }

  private static String encodeBazelTarget(String target) {
    return target.replace(":", ";");
  }

  private static boolean isModeEnabled(String mode) {
    return !"off".equals(mode);
  }

//  private static String[] getPluginParamsFrom(CompileOptions ops) {
//    ArrayList<String> pluginParams = new ArrayList<>(0);
//
//    if (ops.getStrictDepsMode() != EnforcementMode.OFF) {
////      String[] indirectTargets = encodeBazelTargets(ops.indirectTargets);
////      String currentTarget = encodeBazelTarget(ops.currentTarget);
//
//      String[] dependencyAnalyzerParams = {
//        "-P:dependency-analyzer:direct-jars:" + String.join(":", ops.directJars),
//        "-P:dependency-analyzer:indirect-jars:" + String.join(":", ops.indirectJars),
//        "-P:dependency-analyzer:indirect-targets:" + String.join(":", indirectTargets),
//        "-P:dependency-analyzer:mode:" + ops.dependencyAnalyzerMode,
//        "-P:dependency-analyzer:current-target:" + currentTarget,
//      };
//      pluginParams.addAll(Arrays.asList(dependencyAnalyzerParams));
//    } else if (isModeEnabled(ops.unusedDependencyCheckerMode)) {
//      String[] directTargets = encodeBazelTargets(ops.directTargets);
//      String[] ignoredTargets = encodeBazelTargets(ops.ignoredTargets);
//      String currentTarget = encodeBazelTarget(ops.currentTarget);
//
//      String[] unusedDependencyCheckerParams = {
//        "-P:unused-dependency-checker:direct-jars:" + String.join(":", ops.directJars),
//        "-P:unused-dependency-checker:direct-targets:" + String.join(":", directTargets),
//        "-P:unused-dependency-checker:ignored-targets:" + String.join(":", ignoredTargets),
//        "-P:unused-dependency-checker:mode:" + ops.unusedDependencyCheckerMode,
//        "-P:unused-dependency-checker:current-target:" + currentTarget,
//      };
//      pluginParams.addAll(Arrays.asList(unusedDependencyCheckerParams));
//    }
//
//    return pluginParams.toArray(new String[pluginParams.size()]);
//  }

  private static void compileScalaSources(CompileOptions ops, String[] scalaSources, String opsFile, Path tmpPath)
      throws IllegalAccessException {

    List<String> cArgs = new ArrayList<String>();
    cArgs.addAll(ops.getScalacOptsList());
    cArgs.addAll(ops.getPluginsList());
    cArgs.add("-classpath");
    cArgs.add(String.join(File.pathSeparator, ops.getClasspathJarsList()));
    cArgs.add("-d");
    cArgs.add(tmpPath.toString());
    cArgs.add("-P:scala-jdeps:compile-options:" + opsFile);
    cArgs.addAll(Arrays.asList(scalaSources));
    String[] compilerArgs = cArgs.toArray(new String[0]);

//    String[] pluginParams = getPluginParamsFrom(ops);
//
//    String[] constParams = {"-classpath", ops.classpath, "-d", tmpPath.toString()};
//
//    String[] compilerArgs =
//        GenericWorker.merge(ops.scalaOpts, ops.pluginArgs, constParams, pluginParams, scalaSources);

    MainClass comp = new MainClass();
    long start = System.currentTimeMillis();
    try {
      comp.process(compilerArgs);
    } catch (Throwable ex) {
      if (ex.toString().contains("scala.reflect.internal.Types$TypeError")) {
        throw new RuntimeException("Build failure with type error", ex);
      } else {
        throw ex;
      }
    }
    long stop = System.currentTimeMillis();
    if (ops.getPrintCompileTime()) {
      System.err.println("Compiler runtime: " + (stop - start) + "ms.");
    }

    try {
      Files.write(
          Paths.get(ops.getStatsfile()), Arrays.asList("build_time=" + Long.toString(stop - start)));
    } catch (IOException ex) {
      throw new RuntimeException("Unable to write statsfile to " + ops.getStatsfile(), ex);
    }

    ConsoleReporter reporter = (ConsoleReporter) reporterField.get(comp);

    if (reporter.hasErrors()) {
      reporter.printSummary();
      reporter.flush();
      throw new RuntimeException("Build failed");
    }
  }

  private static void removeTmp(Path tmp) throws IOException {
    if (tmp != null) {
      Files.walkFileTree(
          tmp,
          new SimpleFileVisitor<Path>() {
            @Override
            public FileVisitResult visitFile(Path file, BasicFileAttributes attrs)
                throws IOException {
              Files.delete(file);
              return FileVisitResult.CONTINUE;
            }

            @Override
            public FileVisitResult postVisitDirectory(Path dir, IOException exc)
                throws IOException {
              Files.delete(dir);
              return FileVisitResult.CONTINUE;
            }
          });
    }
  }

  private static void copyResources(
      Map<String, Resource> resources, String resourceStripPrefix, Path dest) throws IOException {
    for (Entry<String, Resource> e : resources.entrySet()) {
      Path source = Paths.get(e.getKey());
      Resource resource = e.getValue();
      Path shortPath = Paths.get(resource.getShortPath());
      String dstr;
      // Check if we need to modify resource destination path
      if (!"".equals(resourceStripPrefix)) {
        /**
         * NOTE: We are not using the Resource Hash Value as the destination path when
         * `resource_strip_prefix` present. The path in the hash value is computed by the
         * `_adjust_resources_path` in `scala.bzl`. These are the default paths, ie, path that are
         * automatically computed when there is no `resource_strip_prefix` present. But when
         * `resource_strip_prefix` is present, we need to strip the prefix from the Source Path and
         * use that as the new destination path Refer Bazel -> BazelJavaRuleClasses.java#L227 for
         * details
         */
        dstr = getResourcePath(shortPath, resourceStripPrefix);
      } else {
        dstr = resource.getDestination();
      }
      if (dstr.charAt(0) == '/') {
        // we don't want to copy to an absolute destination
        dstr = dstr.substring(1);
      }
      if (dstr.startsWith("../")) {
        // paths to external repositories, for some reason, start with a leading ../
        // we don't want to copy the resource out of our temporary directory, so
        // instead we replace ../ with external/
        // since "external" is a bit of reserved directory in bazel for these kinds
        // of purposes, we don't expect a collision in the paths.
        dstr = "external" + dstr.substring(2);
      }
      Path target = dest.resolve(dstr);
      File tfile = target.getParent().toFile();
      tfile.mkdirs();
      Files.copy(source, target);
    }
  }

  private static void copyClasspathResourcesToRoot(String[] classpathResourceFiles, Path dest)
      throws IOException {
    for (String s : classpathResourceFiles) {
      Path source = Paths.get(s);
      Path target = dest.resolve(source.getFileName());

      if (Files.exists(target)) {
        System.err.println(
            "Classpath resource file "
                + source.getFileName()
                + " has a namespace conflict with another file: "
                + target.getFileName());
      } else {
        Files.copy(source, target);
      }
    }
  }

  private static String getResourcePath(Path source, String resourceStripPrefix)
      throws RuntimeException {
    String sourcePath = source.toString();
    // check if the Resource file is under the specified prefix to strip
    if (!sourcePath.startsWith(resourceStripPrefix)) {
      // Resource File is not under the specified prefix to strip
      throw new RuntimeException(
          "Resource File "
              + sourcePath
              + " is not under the specified strip prefix "
              + resourceStripPrefix);
    }
    String newResPath = sourcePath.substring(resourceStripPrefix.length());
    return newResPath;
  }

  private static void copyResourceJars(String[] resourceJars, Path dest) throws IOException {
    for (String jarPath : resourceJars) {
      extractJar(jarPath, dest.toString(), null);
    }
  }
}

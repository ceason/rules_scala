package io.bazel.rulesscala.scalac;

import java.io.FileOutputStream;
import java.util.ArrayList;
import java.util.Arrays;
import java.util.LinkedList;
import java.util.List;
import rules_scala.compileoptions.CompileOptionsOuterClass;
import rules_scala.compileoptions.CompileOptionsOuterClass.CompileOptions.Builder;
import rules_scala.compileoptions.CompileOptionsOuterClass.CompileOptions.EnforcementMode;

/**
 *
 */
public class CompileOptionsParser {

  public static void main(String[] args) {
    Builder c = CompileOptionsOuterClass.CompileOptions.newBuilder();
    LinkedList<String> arglist = new LinkedList<>(Arrays.asList(args));
    // the first arg is the output file
    String outputPath = arglist.remove();

    while (!arglist.isEmpty()) {
      String arg = arglist.remove();
      switch (arg) {
        case "--jar_output":
          c.setJarOutput(value(arglist));

        case "--manifest":
          c.setManifest(value(arglist));

        case "--scalac_opts":
          c.addAllScalacOpts(valueList(arglist));

        case "--print_compile_time":
          c.setPrintCompileTime(true);
        case "--print_compile_time=true":
          c.setPrintCompileTime(true);
        case "--print_compile_time=false":
          c.setPrintCompileTime(false);

        case "--expect_java_output":
          c.setExpectJavaOutput(true);
        case "--expect_java_output=true":
          c.setExpectJavaOutput(true);
        case "--expect_java_output=false":
          c.setExpectJavaOutput(false);

        case "--plugins":
          c.addAllPlugins(valueList(arglist));

        case "--classpath_jars":
          c.addAllClasspathJars(valueList(arglist));

        case "--files":
          c.addAllFiles(valueList(arglist));

        case "--java_files":
          c.addAllJavaFiles(valueList(arglist));

        case "--source_jars":
          c.addAllSourceJars(valueList(arglist));

        case "--resource_files":
          String[] parts = value(arglist).split(":", 3);
          String src = parts[0];
          String dest = parts[1];
          String shortPath = parts[2];
          c.putResourceFiles(src, CompileOptionsOuterClass.CompileOptions.Resource
              .newBuilder()
              .setDestination(dest)
              .setShortPath(shortPath)
              .build());

        case "--resource_strip_prefix":
          c.setResourceStripPrefix(value(arglist));

        case "--resource_jars":
          c.addAllResourceJars(valueList(arglist));

        case "--classpath_resource_files":
          c.addAllClasspathResourceFiles(valueList(arglist));

        case "--direct_jars":
          c.addAllDirectJars(valueList(arglist));

        case "--strict_deps_mode":
          c.setStrictDepsMode(EnforcementMode.valueOf(value(arglist).toUpperCase()));

        case "--strict_deps_ignored_jars":
          c.addAllStrictDepsIgnoredJars(valueList(arglist));

        case "--unused_deps_mode":
          c.setUnusedDepsMode(EnforcementMode.valueOf(value(arglist).toUpperCase()));

        case "--unused_deps_ignored_jars":
          c.addAllUnusedDepsIgnoredJars(valueList(arglist));

        case "--current_target":
          c.setCurrentTarget(value(arglist));

        case "--statsfile":
          c.setStatsfile(value(arglist));

        case "--jdeps_output":
          c.setJdepsOutput(value(arglist));

        default:
          throw new IllegalArgumentException(String.format("Unrecognized argument '%s'", arg));
      }
    }

    CompileOptionsOuterClass.CompileOptions opts = c.build();
    try (FileOutputStream out = new FileOutputStream(outputPath)) {
      opts.writeTo(out);
    } catch (Exception e) {
      throw new RuntimeException(e);
    }
  }

  private static List<String> valueList(LinkedList<String> args) {
    List<String> r = new ArrayList<String>();
    r.add(args.remove());
    while (!args.isEmpty() && !args.peek().startsWith("--")) {
      r.add(args.remove());
    }
    return r;
  }

  private static String value(LinkedList<String> args) {
    String v = args.remove();
    if (!args.isEmpty() && !args.peek().startsWith("--")) {
      throw new IllegalArgumentException("Got multiple values for single value arg");
    }
    return v;
  }

}

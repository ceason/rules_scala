package io.bazel.rulesscala.scalac;

import com.google.devtools.build.lib.view.proto.Deps.Dependencies;
import io.bazel.rulesscala.scalac.JdepsEnforcer.EnforcementMode;
import java.util.ArrayList;
import java.util.Arrays;
import java.util.List;

/**
 * For merging java & scala complation output - merges class jars - merges .jdeps - enforces
 * strict/unused deps
 */
public class JdepsJarMerger extends Options {

  List<String> inputJdeps = new ArrayList<>();
  List<String> inputJars = new ArrayList<>();
  String outputJar;
  String outputJdeps;
  List<String> enforcerArgs = new ArrayList<>();

  JdepsJarMerger(List<String> args) {
    super(args);
    while (hasMoreFlags()) {
      String flag = nextFlag();
      switch (flag) {
        case "--output_jar":
          outputJar = getValue();
          break;
        case "--output_jdeps":
          outputJdeps = getValue();
          break;
        case "--input_jar":
          inputJars.add(getValue());
          break;
        case "--input_jdeps":
          inputJdeps.add(getValue());
          break;
        default:
          // pass other args through to deps enforcer
          enforcerArgs.add(flag);
          enforcerArgs.add(getValue());
      }
    }
  }

  // merge jars to output jar
  void writeOutputJar() {
    throw new RuntimeException("Unimplemented.");
  }

  // merge jars to output jar
  Dependencies writeOutputJdeps() {
    throw new RuntimeException("Unimplemented.");
  }

  public static void main(String[] args) {
    JdepsJarMerger jm = new JdepsJarMerger(Arrays.asList(args));
    Dependencies jdeps = jm.writeOutputJdeps();
    JdepsEnforcer enforcer = new JdepsEnforcer(jdeps, jm.enforcerArgs);
    for (String msg : enforcer.getViolatingStrictDeps()) {
      System.err.println(msg);
      if (enforcer.strictDeps == EnforcementMode.ERROR) {
        System.exit(1);
      }
    }
    if (enforcer.unusedDeps != EnforcementMode.OFF) {
      for (String msg : enforcer.getViolatingUnusedDeps()) {
        System.err.println(msg);
        if (enforcer.unusedDeps == EnforcementMode.ERROR) {
          System.exit(1);
        }
      }
      ;
    }
    jm.writeOutputJar();
  }
}

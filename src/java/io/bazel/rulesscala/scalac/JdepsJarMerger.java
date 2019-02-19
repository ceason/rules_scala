package io.bazel.rulesscala.scalac;

import java.util.ArrayList;
import java.util.Arrays;
import java.util.List;

/**
 * For merging java & scala complation output - merges class jars - merges .jdeps - enforces
 * strict/unused deps
 */
public class JdepsJarMerger extends Options {

  List<String> jdeps = new ArrayList<>();
  List<String> jars = new ArrayList<>();
  String outputJar;
  String outputJdeps;
  JdepsEnforcer enforcer;

  JdepsJarMerger(List<String> args) {

    super(args);
    List<String> enforcerArgs = new ArrayList<>();
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
          jars.add(getValue());
          break;
        case "--input_jdeps":
          jdeps.add(getValue());
          break;
        default:
          // pass other args through to deps enforcer
          enforcerArgs.add(flag);
          enforcerArgs.add(getValue());
      }
    }
    enforcer = new JdepsEnforcer(enforcerArgs);
  }

  public static void main(String[] args) {
    JdepsJarMerger jm = new JdepsJarMerger(Arrays.asList(args));

  }
}

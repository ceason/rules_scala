package io.bazel.rulesscala.scalac;

import com.google.devtools.build.lib.view.proto.Deps.Dependencies;
import com.google.devtools.build.lib.view.proto.Deps.Dependency;
import com.google.devtools.build.lib.view.proto.Deps.Dependency.Kind;
import java.io.File;
import java.io.IOException;
import java.util.HashMap;
import java.util.HashSet;
import java.util.List;
import java.util.Map;
import java.util.Set;
import java.util.function.Predicate;
import java.util.jar.JarFile;
import java.util.stream.Collectors;

/**
 * Enforces strict/unused deps
 */
public class JdepsEnforcer extends Options {

  enum EnforcementMode {OFF, ERROR, WARN}

  EnforcementMode strictDeps = EnforcementMode.OFF;
  EnforcementMode unusedDeps = EnforcementMode.OFF;
  Set<String> unusedDepsIgnoredJars = new HashSet<>();
  Set<String> strictDepsIgnoredJars = new HashSet<>();
  Set<String> directJars = new HashSet<>();
  Map<String, String> depsExportedLabels = new HashMap<>();
  Set<String> usedJars;
  Set<String> usedLabels;
  Set<String> directLabels;
  String currentTarget;

  JdepsEnforcer(Dependencies jdeps, List<String> args) {
    super(args);
    while (hasMoreFlags()) {
      switch (nextFlag()) {
        case "--strict_deps_mode":
          strictDeps = EnforcementMode.valueOf(getValue().toUpperCase());
          break;
        case "--unused_deps_mode":
          unusedDeps = EnforcementMode.valueOf(getValue().toUpperCase());
          break;
        case "--unused_deps_ignored_jars":
          unusedDepsIgnoredJars.addAll(getList(File.pathSeparator));
          break;
        case "--strict_deps_ignored_jars":
          strictDepsIgnoredJars.addAll(getList(File.pathSeparator));
          break;
        case "--direct_jars":
          directJars.addAll(getList(File.pathSeparator));
          break;
        case "--deps_exported_labels":
          String[] parts = getValue().split("::");
          if (parts.length != 2) {
            throw new IllegalArgumentException(String.format(
                "Flag --deps_exported_labels wanted pair of '::' delimited values but got '%s'",
                String.join("::")));
          }
          depsExportedLabels.put(parts[0], parts[1]);
          break;
        default:
          throw unrecognizedFlagException();
      }
    }
    currentTarget = jdeps.getRuleLabel();
    usedJars = jdeps.getDependencyList().stream()
        .filter(d -> d.getKind() == Kind.EXPLICIT)
        .map(Dependency::getPath)
        .collect(Collectors.toSet());
    usedLabels = usedJars.stream()
        .map(this::getLabelFromJar)
        .map(this::resolveExportedLabel)
        .collect(Collectors.toSet());
    directLabels = directJars.stream()
        .map(this::getLabelFromJar)
        .collect(Collectors.toSet());
  }

  List<String> getViolatingUnusedDeps() {
    return directJars.stream()
        .filter(not(usedJars::contains))
        .filter(not(unusedDepsIgnoredJars::contains))
        .filter(this::jarHasClassfiles)
        .map(this::getLabelFromJar)
        .map(this::resolveExportedLabel)
        .filter(not(usedLabels::contains))
        .map(target -> (
                "Target '{target}' is specified as a dependency to {currentTarget} but isn't used, please remove it from the deps.\n"
                    + "You can use the following buildozer command:\n"
                    + "buildozer 'remove deps {target}' {currentTarget}"
//                + "\nUSED_JARS:\n  " + usedJars.stream().sorted().collect(Collectors.joining("\n  "))
//                + "\nUSED_LABELS:\n  " + usedLabels.stream().sorted().collect(Collectors.joining("\n  "))
//                + "\nIGNORED_JARS:\n  " + unusedDepsIgnoredJars.stream().sorted().collect(Collectors.joining("\n  "))
            )
                .replace("{target}", target)
                .replace("{currentTarget}", currentTarget)
        )
        .collect(Collectors.toList());
  }

  List<String> getViolatingStrictDeps() {
    return usedJars.stream()
        .filter(not(directJars::contains))
        .filter(not(strictDepsIgnoredJars::contains))
        .filter(this::jarHasClassfiles)
        .map(this::getLabelFromJar)
        .map(this::resolveExportedLabel)
        .map(target -> (
                "Target '{target}' is used but isn't explicitly declared, please add it to the deps.\n"
                    + "You can use the following buildozer command:\n"
                    + "buildozer 'add deps {target}' {currentTarget}"
//              + "\nUSED_JARS:\n  " + usedJars.stream().sorted().collect(Collectors.joining("\n  "))
//              + "\nUSED_LABELS:\n  " + usedLabels.stream().sorted().collect(Collectors.joining("\n  "))
//              + "\nDIRECT_JARS:\n  " + directJars.stream().sorted().collect(Collectors.joining("\n  "))
            )
                .replace("{target}", target)
                .replace("{currentTarget}", currentTarget)
        )
        .collect(Collectors.toList());
  }


  String getLabelFromJar(String jarPath) {
    // extract target label from jar
    try (JarFile jar = new JarFile(jarPath)) {
      return jar.getManifest()
          .getMainAttributes()
          .getValue("Target-Label");
    } catch (IOException e) {
      return jarPath;
    }
  }

  boolean jarHasClassfiles(String jarPath) {
    try (JarFile jar = new JarFile(jarPath)) {
      return jar.stream()
          .anyMatch(f -> f.getName().endsWith(".class"));
    } catch (IOException e) {
      throw new RuntimeException("Couldn't open " + jarPath, e);
    }
  }

  String resolveExportedLabel(String label) {
    return depsExportedLabels.getOrDefault(label, label);
  }

  public static <T> Predicate<T> not(Predicate<T> t) {
    return t.negate();
  }

}

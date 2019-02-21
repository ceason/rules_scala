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
  //  Set<String> unusedDepsIgnoredJars = new HashSet<>();
  Set<String> unusedDepsIgnoredLabels = new HashSet<>();
  Set<String> strictDepsIgnoredJars = new HashSet<>();
  Set<String> directJars = new HashSet<>();
  Map<String, String> depsExportedLabels = new HashMap<>();
  Set<String> usedJars;
  Set<String> directLabels = new HashSet<>();
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
        case "--unused_deps_ignored_labels":
          unusedDepsIgnoredLabels.addAll(getList("::"));
          break;
        case "--direct_labels":
          directLabels.addAll(getList("::"));
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
  }

  List<String> getViolatingUnusedDeps() {
    Set<String> usedLabels = usedJars.stream()
        .filter(this::jarHasClassfiles)
        .map(this::getLabelFromJar)
        .collect(Collectors.toSet());

    Set<String> resolvedUsedLabels = usedLabels.stream()
        .map(this::resolveExportedLabel)
        .filter(not(usedLabels::contains))
        .collect(Collectors.toSet());

    return directLabels.stream()
        .filter(not(unusedDepsIgnoredLabels::contains))
        .filter(not(usedLabels::contains))
        .filter(not(resolvedUsedLabels::contains))
        .map(target -> (
                "Target '{target}' is specified as a dependency to {currentTarget} but isn't used, please remove it from the deps.\n"
                    + "You can use the following buildozer command:\n"
                    + "buildozer 'remove deps {target}' {currentTarget}"
                    + "\nUSED_JARS:\n  " + usedJars.stream().sorted()
                    .collect(Collectors.joining("\n  "))
                    + "\nUSED_LABELS:\n  " + usedLabels.stream().sorted()
                    .collect(Collectors.joining("\n  "))
                    + "\nRESOLVED_USED_LABELS:\n  " + resolvedUsedLabels.stream().sorted()
                    .collect(Collectors.joining("\n  "))
                    + "\nDIRECT_LABELS:\n  " + directLabels.stream().sorted()
                    .collect(Collectors.joining("\n  "))
                    + "\nIGNORED_LABELS:\n  " + unusedDepsIgnoredLabels.stream().sorted()
                    .collect(Collectors.joining("\n  "))
                    + "\nDEPS_EXPORTED_LABELS:\n  " + depsExportedLabels.keySet().stream().sorted()
                    .map(k -> String.format("%s => %s", k, depsExportedLabels.get(k)))
                    .collect(Collectors.joining("\n  "))
            )
                .replace("{target}", target)
                .replace("{currentTarget}", currentTarget)
        )
        .collect(Collectors.toList());
  }

  List<String> getViolatingStrictDeps() {
    return usedJars.stream()
        .filter(not(strictDepsIgnoredJars::contains))
        .filter(not(directJars::contains))
        .map(this::getLabelFromJar)
        .filter(not(directLabels::contains))
        .map(this::resolveExportedLabel)
        .filter(not(directLabels::contains))
        .map(target -> (
                "Target '{target}' is used but isn't explicitly declared, please add it to the deps.\n"
                    + "You can use the following buildozer command:\n"
                    + "buildozer 'add deps {target}' {currentTarget}"
                    + "\nUSED_JARS:\n  " + usedJars.stream().sorted().collect(Collectors.joining("\n  "))
                    + "\nIGNORED_JARS:\n  " + strictDepsIgnoredJars.stream().sorted().collect(Collectors.joining("\n  "))
              + "\nDIRECT_JARS:\n  " + directJars.stream().sorted().collect(Collectors.joining("\n  "))
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
    } catch (IllegalArgumentException e) {
      return jarPath;
    } catch (IOException e) {
      throw new RuntimeException(e);
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

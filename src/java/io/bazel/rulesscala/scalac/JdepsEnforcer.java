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
import java.util.stream.Stream;

/**
 * Enforces strict/unused deps
 */
public class JdepsEnforcer extends Options {

  enum EnforcementMode {OFF, ERROR, WARN}

  EnforcementMode strictDeps = EnforcementMode.OFF;
  EnforcementMode unusedDeps = EnforcementMode.OFF;
  Set<String> unusedDepsIgnoredLabels = new HashSet<>();
  Set<String> strictDepsIgnoredJars = new HashSet<>();
  Set<String> directJars = new HashSet<>();
  Set<String> usedJars;
  Set<String> directLabels = new HashSet<>();
  Map<String, String> suggestedDepByLabel = new HashMap<>();
  Map<String, Set<String>> aliasesByLabel = new HashMap<>();
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
        case "--aliased_labels":
          String[] parts = getValue().split("::");
          if (!(parts.length > 1)) {
            throw new IllegalArgumentException(String.format(
                "Flag --aliased_labels wanted > 1 '::' delimited values but got '%s'",
                String.join("::", parts)));
          }
          String alias = parts[0];
          for (int i = 1; i < parts.length; i++) {
            String label = parts[i];
            if (!aliasesByLabel.containsKey(label)) {
              aliasesByLabel.put(label, new HashSet<>());
            }
            aliasesByLabel.get(label).add(alias);
            suggestedDepByLabel.putIfAbsent(label, alias);
          }
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
    return directJars.stream()
        .filter(not(usedJars::contains))     // = unused direct jars
        .filter(this::jarHasClassfiles)
        .map(this::getLabelFromJar)          // = "maybe" unused-direct labels
        .filter(not(directLabels::contains))
        .filter(not(this::isDirectViaAlias)) // = actual unused labels
        .flatMap(this::labelWithAllAliases)  // ..including their aliases
        .filter(directLabels::contains)      // filtered by what is actually specified in `deps`
        .map(target -> (
                "Target '{target}' is specified as a dependency to {currentTarget} but isn't used, please remove it from the deps.\n"
                    + "You can use the following buildozer command:\n"
                    + "buildozer 'remove deps {target}' {currentTarget}"
                    + "\nUSED_JARS:\n  " + usedJars.stream().sorted().collect(Collectors.joining("\n  "))
                    + "\nDIRECT_LABELS:\n  " + directLabels.stream().sorted().collect(Collectors.joining("\n  "))
                    + "\nIGNORED_LABELS:\n  " + unusedDepsIgnoredLabels.stream().sorted().collect(Collectors.joining("\n  "))
            )
                .replace("{target}", target)
                .replace("{currentTarget}", currentTarget)
        )
        .collect(Collectors.toList());
  }

  List<String> getViolatingStrictDeps() {
    List<String> violatingJars = usedJars.stream()
        .filter(not(strictDepsIgnoredJars::contains))
        .filter(not(directJars::contains))
        .collect(Collectors.toList());
    return violatingJars.stream()
        .map(this::getLabelFromJar)
        .map(this::suggestAddDepLabel)
        .map(target -> (
                "Target '{target}' is used but isn't explicitly declared, please add it to the deps.\n"
                    + "You can use the following buildozer command:\n"
                    + "buildozer 'add deps {target}' {currentTarget}"
                    + "\nVIOLATING_JARS:\n  " + violatingJars.stream().sorted().collect(Collectors.joining("\n  "))
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

  boolean isDirectViaAlias(String label) {
    // for each alias of my label, see if 'usedLabels' contains..
    if (aliasesByLabel.containsKey(label)) {
      for (String alias : aliasesByLabel.get(label)) {
        if (directLabels.contains(alias)) {
          return true;
        }
      }
    }
    return false;
  }

  Stream<String> labelWithAllAliases(String label) {
    if (aliasesByLabel.containsKey(label)) {
      return Stream.concat(
          Stream.of(label),
          aliasesByLabel.get(label).stream());
    } else {
      return Stream.of(label);
    }
  }

  String suggestAddDepLabel(String label) {
    return suggestedDepByLabel.getOrDefault(label, label);
  }

  public static <T> Predicate<T> not(Predicate<T> t) {
    return t.negate();
  }

}

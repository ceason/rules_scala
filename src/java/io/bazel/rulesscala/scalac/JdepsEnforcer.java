package io.bazel.rulesscala.scalac;

import com.google.devtools.build.lib.view.proto.Deps.Dependencies;
import com.google.devtools.build.lib.view.proto.Deps.Dependency;
import com.google.devtools.build.lib.view.proto.Deps.Dependency.Kind;
import java.io.File;
import java.io.IOException;
import java.util.Arrays;
import java.util.Collections;
import java.util.HashMap;
import java.util.HashSet;
import java.util.LinkedList;
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
public class JdepsEnforcer {

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
    Options o = new Options(args);
    LinkedList<String> aliasedLabels = new LinkedList<>();
    while (o.hasMoreFlags()) {
      switch (o.nextFlag()) {
        case "--strict_deps_mode":
          strictDeps = EnforcementMode.valueOf(o.getValue().toUpperCase());
          break;
        case "--unused_deps_mode":
          unusedDeps = EnforcementMode.valueOf(o.getValue().toUpperCase());
          break;
        case "--unused_deps_ignored_labels":
          unusedDepsIgnoredLabels.addAll(o.getList("::"));
          break;
        case "--direct_labels":
          directLabels.addAll(o.getList("::"));
          break;
        case "--strict_deps_ignored_jars":
          strictDepsIgnoredJars.addAll(o.getList(File.pathSeparator));
          break;
        case "--direct_jars":
          directJars.addAll(o.getList(File.pathSeparator));
          break;
        case "--aliased_labels":
          aliasedLabels.add(o.getValue());
          break;
        default:
          throw o.unrecognizedFlagException();
      }
    }
    currentTarget = jdeps.getRuleLabel();
    usedJars = jdeps.getDependencyList().stream()
        .filter(d -> d.getKind() == Kind.EXPLICIT)
        .map(Dependency::getPath)
        .collect(Collectors.toSet());
    // consume aliased labels in reverse (topological) order, which allows "nearer"
    // aliases to override/propagate to "farther" ones.
    while(!aliasedLabels.isEmpty()) {
      String[] parts = aliasedLabels.removeLast().split("::");
      if (!(parts.length > 1)) {
        throw new IllegalArgumentException(String.format(
            "Flag --aliased_labels wanted > 1 '::' delimited values but got '%s'",
            String.join("::", parts)));
      }
      String alias = parts[0].intern();
      String suggestedDep = suggestedDepByLabel.getOrDefault(alias, alias);
      Set<String> extraAliases = aliasesByLabel.getOrDefault(alias, Collections.emptySet());
      for (int i = 1; i < parts.length; i++) {
        String label = parts[i].intern();
        suggestedDepByLabel.putIfAbsent(label, suggestedDep);
        if (!aliasesByLabel.containsKey(label)) {
          aliasesByLabel.put(label, new HashSet<>());
        }
        Set<String> aliases = aliasesByLabel.get(label);
        aliases.add(alias);
        aliases.addAll(extraAliases);
      }
    }
  }

  List<String> getViolatingUnusedDeps() {
    Set<String> directUsedLabels = usedJars.stream()
        .filter(directJars::contains)
        .map(this::getLabelFromJar)
        .flatMap(this::labelWithAllAliases)
        .filter(directLabels::contains)
        .collect(Collectors.toSet());
    Set<String> unusedLabels = new HashSet<>();
    for (String label : directLabels) {
      Set<String> aliases = aliasesByLabel.getOrDefault(label, Collections.emptySet());
      // label is only unused if it's not used or ignored
      if (!directUsedLabels.contains(label) &&
          !unusedDepsIgnoredLabels.contains(label) &&
          // AND none of its aliases are used or ignored either
          Collections.disjoint(aliases, unusedDepsIgnoredLabels) &&
          Collections.disjoint(aliases, directUsedLabels)) {
        unusedLabels.add(label);
      }
    }
//    Set<String> wtf = usedJars.stream()
//        .map(this::getLabelFromJar)
//        .collect(Collectors.toSet());
//    Set<String> wtf2 = usedJars.stream()
//        .map(this::getLabelFromJar)
//        .flatMap(this::labelWithAllAliases)
//        .collect(Collectors.toSet());
//    if (currentTarget.equals("//test/src/main/scala/scalarules/test/twitter_scrooge:justscrooges")) {
//      return Arrays.asList("its the thing!!!!!"
//    + "\nSTRICT_MODE: " + strictDeps.toString()
//        + "\nUNUSED_MODE: " + unusedDeps.toString()
//        + "\nUSED_JARS:\n  " + usedJars.stream().sorted().collect(Collectors.joining("\n  "))
//        + "\nDIRECT_JARS:\n  " + directJars.stream().sorted().collect(Collectors.joining("\n  "))
//        + "\nDIRECT_LABELS:\n  " + directLabels.stream().sorted().collect(Collectors.joining("\n  "))
//        + "\nIGNORED_LABELS:\n  " + unusedDepsIgnoredLabels.stream().sorted().collect(Collectors.joining("\n  "))
//        + "\nALIASED_LABELS:\n  " + aliasesByLabel.keySet().stream().sorted().map(k -> String.format("%s => %s", k, aliasesByLabel.get(k))).collect(Collectors.joining("\n  "))
//        + "\nDIRECT_USED_LABELS:\n  " + directUsedLabels.stream().sorted().collect(Collectors.joining("\n  "))
//        + "\nUNUSED_LABELS:\n  " + unusedLabels.stream().sorted().collect(Collectors.joining("\n  "))
//          + "\nWTF:\n  " + wtf.stream().sorted().collect(Collectors.joining("\n  "))
//          + "\nWTF2:\n  " + wtf2.stream().sorted().collect(Collectors.joining("\n  ")));
//
//    }

    if (unusedLabels.size() == 0){
      return Collections.emptyList();
    } else {
      String message = ("Unused dependencies found for {currentTarget}.\n"
          + "You can use the following buildozer command to remove:\n"
          + "buildozer 'remove deps {targets}' {currentTarget}"
          + "\nSTRICT_MODE: " + strictDeps.toString()
          + "\nUNUSED_MODE: " + unusedDeps.toString()
//              + "\nUSED_JARS:\n  " + usedJars.stream().sorted().collect(Collectors.joining("\n  "))
//              + "\nDIRECT_JARS:\n  " + directJars.stream().sorted().collect(Collectors.joining("\n  "))
//              + "\nDIRECT_LABELS:\n  " + directLabels.stream().sorted().collect(Collectors.joining("\n  "))
//              + "\nIGNORED_LABELS:\n  " + unusedDepsIgnoredLabels.stream().sorted().collect(Collectors.joining("\n  "))
//              + "\nALIASED_LABELS:\n  " + aliasesByLabel.keySet().stream().sorted().map(k -> String.format("%s => %s", k, aliasesByLabel.get(k))).collect(Collectors.joining("\n  "))
          + "\nDIRECT_USED_LABELS:\n  " + directUsedLabels.stream().sorted().collect(Collectors.joining("\n  "))
          + "\nUNUSED_LABELS:\n  " + unusedLabels.stream().sorted().collect(Collectors.joining("\n  "))
      )
          .replace("{targets}", unusedLabels.stream().sorted().collect(Collectors.joining(" ")))
          .replace("{currentTarget}", currentTarget);
      return Arrays.asList(message);
    }

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
                    + "\nALIASED_LABELS:\n  " + aliasesByLabel.keySet().stream().sorted().map(k -> String.format("%s => %s", k, aliasesByLabel.get(k))).collect(Collectors.joining("\n  "))
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


  Stream<String> labelWithAllAliases(String label) {
    return Stream.concat(
        Stream.of(label),
        aliasesByLabel.getOrDefault(label, Collections.emptySet()).stream());
  }

  String suggestAddDepLabel(String label) {
    return suggestedDepByLabel.getOrDefault(label, label);
  }

  public static <T> Predicate<T> not(Predicate<T> t) {
    return t.negate();
  }

}

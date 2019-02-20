package io.bazel.rulesscala.scalac;

import com.google.devtools.build.lib.view.proto.Deps.Dependencies;
import com.google.devtools.build.lib.view.proto.Deps.Dependency;
import com.google.devtools.build.lib.view.proto.Deps.Dependency.Kind;
import io.bazel.rulesscala.scalac.JdepsEnforcer.EnforcementMode;
import java.io.FileInputStream;
import java.io.FileOutputStream;
import java.io.IOException;
import java.util.ArrayList;
import java.util.Arrays;
import java.util.HashSet;
import java.util.List;
import java.util.Set;
import java.util.jar.Attributes;
import java.util.jar.JarEntry;
import java.util.jar.JarInputStream;
import java.util.jar.JarOutputStream;
import java.util.jar.Manifest;
import java.util.stream.Collectors;

/**
 * For merging java & scala complation output - merges class jars - merges .jdeps - enforces
 * strict/unused deps
 */
public class JdepsJarMerger extends Options {

  List<String> inputJdeps = new ArrayList<>();
  Set<String> inputJars = new HashSet<>();
  String outputJar;
  String outputJdeps;
  String ruleLabel;
  List<String> enforcerArgs = new ArrayList<>();

  JdepsJarMerger(List<String> args) {
    super(args);
    while (hasMoreFlags()) {
      String flag = nextFlag();
      switch (flag) {
        case "--rule_label":
          ruleLabel = getValue();
          break;
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
          enforcerArgs.addAll(getList());
      }
    }
  }

  // merge jars to output jar
  void writeOutputJar() {
    Manifest manifest = new Manifest();
    manifest.getMainAttributes().put(Attributes.Name.MANIFEST_VERSION, "1.0");
    byte[] buffer = new byte[1024];
    int len = 0;
    JarEntry e;
    try (JarOutputStream out = new JarOutputStream(new FileOutputStream(outputJar), manifest)) {
      for (String jarPath : inputJars) {
        try (JarInputStream jis = new JarInputStream(new FileInputStream(jarPath))) {
          while ((e = jis.getNextJarEntry()) != null) {
            out.putNextEntry(e);
            while ((len = jis.read(buffer)) > 0) {
              out.write(buffer, 0, len);
            }
          }
        }
      }
    } catch (IOException err) {
      throw new RuntimeException(err);
    }
  }

  // merge jars to output jdeps
  Dependencies writeOutputJdeps() {
    Set<String> containedPackage = new HashSet<>();
    Set<String> allDeps = new HashSet<>();
    Set<String> explicitDeps = new HashSet<>();
    Set<String> implicitDeps = new HashSet<>();
    Set<String> unusedDeps = new HashSet<>();

    boolean success = true;

    Dependencies.Builder deps = Dependencies.newBuilder();
    Dependencies out;

    // read jdeps into our accumulated state of what kind of deps they are
    for (String jdepPath : inputJdeps) {
      try (FileInputStream fin = new FileInputStream(jdepPath)) {
        Dependencies input = Dependencies.parseFrom(fin);
        if (input.hasSuccess() && !input.getSuccess()) {
          success = false;
        }
        containedPackage.addAll(input.getContainedPackageList());
        for (Dependency dep : input.getDependencyList()) {
          if (inputJars.contains(dep.getPath())) {
            continue; // elide/skip input jars
          }
          allDeps.add(dep.getPath());
          switch (dep.getKind()) {
            case EXPLICIT:
              explicitDeps.add(dep.getPath());
              break;
            case IMPLICIT:
              implicitDeps.add(dep.getPath());
              break;
            case UNUSED:
              unusedDeps.add(dep.getPath());
              break;
          }
        }
      } catch (IOException e) {
        throw new RuntimeException("couldn't read " + jdepPath, e);
      }
    }

    // create 'combined jdeps' from accumulated info
    try (FileOutputStream fos = new FileOutputStream(outputJdeps)) {
      for (String d : allDeps.stream().sorted().collect(Collectors.toList())) {
        Dependency.Builder dep = Dependency.newBuilder();
        dep.setPath(d);
        if (explicitDeps.contains(d)) {
          dep.setKind(Kind.EXPLICIT);
        } else if (implicitDeps.contains(d)) {
          dep.setKind(Kind.IMPLICIT);
        } else if (unusedDeps.contains(d)) {
          dep.setKind(Kind.UNUSED);
        } else {
          dep.setKind(Kind.INCOMPLETE);
        }
        deps.addDependency(dep.build());
      }
      deps.setRuleLabel(ruleLabel);
      deps.setSuccess(success);
      deps.addAllContainedPackage(containedPackage.stream()
          .sorted().collect(Collectors.toList()));
      out = deps.build();
      out.writeTo(fos);
    } catch (IOException e) {
      throw new RuntimeException(e);
    }
    return out;
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
    }
    jm.writeOutputJar();
  }
}

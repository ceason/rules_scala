package io.bazel.rulesscala.scalac;

import java.util.ArrayList;
import java.util.LinkedList;
import java.util.List;

public class CompileOptions {

  public boolean printCompileTime = false;
  public final List<String> scalacOpts = new ArrayList<>();
  public final List<String> sources = new ArrayList<>();
  public String outputStatsfile;

  private String currentFlag;

  public CompileOptions(List<String> args) {
    LinkedList<String> arglist = new LinkedList<>(args);

    while (!arglist.isEmpty()) {
      currentFlag = arglist.remove();

      switch (currentFlag) {
        case "--print_compile_time":
          printCompileTime = true;
          break;
        case "--scalac_opts":
          scalacOpts.addAll(getList(arglist));
          break;
        case "--sources":
          sources.addAll(getList(arglist));
          break;
        case "--output_statsfile":
          outputStatsfile = getValue(arglist);
          break;
        default:
          throw new RuntimeException(String.format("Unrecognized argument '%s'", currentFlag));
      }

    }

    // do some validation
    if (sources.isEmpty()) {
      throw new IllegalArgumentException(
          "Must have input files from either source jars or local files.");
    }
  }

  private String getValue(LinkedList<String> args) {
    String v = args.remove();
    if (!args.isEmpty() && !args.peek().startsWith("--")) {
      throw new IllegalArgumentException(
          "Got multiple values for single value flag " + currentFlag);
    }
    return v;
  }

  private List<String> getList(LinkedList<String> args) {
    List<String> r = new ArrayList<String>();
    while (!args.isEmpty() && !args.peek().startsWith("--")) {
      r.add(args.remove());
    }
    if (r.isEmpty()) {
      throw new IllegalArgumentException("No values specified for flag " + currentFlag);
    }
    return r;
  }


}

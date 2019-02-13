package io.bazel.rulesscala.scalac;

import java.util.ArrayList;
import java.util.LinkedList;
import java.util.List;
import java.util.Queue;

public class CompileOptions {

  public boolean printCompileTime = false;
  public final List<String> scalacOpts = new ArrayList<>();
  public final List<String> sources = new ArrayList<>();
  public String outputStatsfile;

  public CompileOptions(List<String> args) {
    LinkedList<String> arglist = new LinkedList<>(args);
    while (!arglist.isEmpty()) {
      String arg = arglist.remove();
      switch (arg) {
        case "--print_compile_time":
          printCompileTime = true;
        case "--scalac_opts":
          scalacOpts.addAll(getList(arglist));
        case "--sources":
          sources.addAll(getList(arglist));
        case "--output_statsfile":
          outputStatsfile = getValue(arglist);
        default:
          throw new IllegalArgumentException(String.format("Unrecognized argument '%s'", arg));
      }
    }
    // do some validation
    if (sources.isEmpty()) {
      throw new IllegalArgumentException(
          "Must have input files from either source jars or local files.");
    }
  }

  private static String getValue(Queue<String> args) {
    String v = args.remove();
    if (!args.isEmpty() && !args.peek().startsWith("--")) {
      throw new IllegalArgumentException("Got multiple values for single value arg");
    }
    return v;
  }

  private static List<String> getList(Queue<String> args) {
    List<String> r = new ArrayList<String>();
    r.add(args.remove());
    while (!args.isEmpty() && !args.peek().startsWith("--")) {
      r.add(args.remove());
    }
    return r;
  }

}

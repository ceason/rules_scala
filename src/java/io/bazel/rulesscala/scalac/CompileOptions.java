package io.bazel.rulesscala.scalac;

import java.util.ArrayList;
import java.util.List;

public class CompileOptions extends Options {

  public boolean printCompileTime = false;
  public final List<String> scalacOpts = new ArrayList<>();
  public final List<String> sources = new ArrayList<>();
  public String outputStatsfile;

  public CompileOptions(List<String> args) {
    super(args);
    while (hasMoreFlags()) {
      switch (nextFlag()) {
        case "--print_compile_time":
          printCompileTime = true;
          break;
        case "--scalac_opts":
          scalacOpts.addAll(getList());
          break;
        case "--sources":
          sources.addAll(getList());
          break;
        case "--output_statsfile":
          outputStatsfile = getValue();
          break;
        default:
          throw unrecognizedFlagException();
      }
    }

    // do some validation
    if (sources.isEmpty()) {
      throw new IllegalArgumentException(
          "Must have input files from either source jars or local files.");
    }
  }
}

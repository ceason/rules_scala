package io.bazel.rulesscala.scalac;

import io.bazel.rulesscala.worker.Processor;
import java.io.IOException;
import java.io.PrintWriter;
import java.lang.reflect.Field;
import java.util.ArrayList;
import java.util.List;
import scala.tools.nsc.Driver;
import scala.tools.nsc.MainClass;
import scala.tools.nsc.reporters.ConsoleReporter;

class ScalacProcessor implements Processor {

  /**
   * This is the reporter field for scalac, which we want to access
   */
  private static Field reporterField;

  static {
    try {
      reporterField = Driver.class.getDeclaredField("reporter"); // NoSuchFieldException
      reporterField.setAccessible(true);
    } catch (NoSuchFieldException ex) {
      throw new RuntimeException("could not access reporter field on Driver", ex);
    }
  }

  @Override
  public void processRequest(List<String> args) throws Exception {
    CompileOptions ops = new CompileOptions(args);
    MainClass comp = new MainClass();
    List<String> compilerArgs = new ArrayList();
    compilerArgs.addAll(ops.scalacOpts);
    compilerArgs.addAll(ops.sources);
    long start = System.currentTimeMillis();
    try {
      comp.process(compilerArgs.toArray(new String[0]));
    } catch (Throwable ex) {
      if (ex.toString().contains("scala.reflect.internal.Types$TypeError")) {
        throw new RuntimeException("Build failure with type error", ex);
      } else {
        throw ex;
      }
    }
    long duration = System.currentTimeMillis() - start;
    if (ops.printCompileTime) {
      System.err.println("Compiler runtime: " + duration + "ms.");
    }
    if (ops.outputStatsfile != null) {
      try (PrintWriter statsfile = new PrintWriter(ops.outputStatsfile)) {
        statsfile.write("build_time=" + duration);
      } catch (IOException ex) {
        throw new RuntimeException("Unable to write statsfile to " + ops.outputStatsfile, ex);
      }
    }
    ConsoleReporter reporter = (ConsoleReporter) reporterField.get(comp);
    if (reporter.hasErrors()) {
      reporter.printSummary();
      reporter.flush();
      throw new RuntimeException("Build failed");
    }
  }
}

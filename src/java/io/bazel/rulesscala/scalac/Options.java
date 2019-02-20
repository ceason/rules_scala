package io.bazel.rulesscala.scalac;

import java.util.ArrayList;
import java.util.Arrays;
import java.util.LinkedList;
import java.util.List;
import java.util.Queue;

/**
 *
 */
public class Options {

  private String currentFlag;
  private Queue<String> args;
  private String[] originalArgs;


  protected Options(List<String> args) {
    this.args = new LinkedList<>(args);
    originalArgs = args.toArray(new String[0]);
  }

  protected RuntimeException unrecognizedFlagException() {
    return new RuntimeException(String.format(""
            + "Unrecognized argument '%s' in args:\n  %s",
        currentFlag, String.join("\n  ", args)));
  }

  protected boolean hasMoreFlags() {
    return !args.isEmpty();
  }

  protected String nextFlag() {
    currentFlag = args.remove();
    return currentFlag;
  }

  protected String getValue() {
    String v = args.remove();
    if (!args.isEmpty() && !args.peek().startsWith("--")) {
      throw new IllegalArgumentException(
          "Got multiple values for single value flag " + currentFlag + "\n  " + String
              .join("\n  ", originalArgs));
    }
    return v;
  }

  protected List<String> getList() {
    return getList(null);
  }

  protected List<String> getList(String splitStr) {
    List<String> r = new ArrayList<String>();
    while (!args.isEmpty() && !args.peek().startsWith("--")) {
      String item = args.remove();
      if (splitStr != null) {
        r.addAll(Arrays.asList(item.split(splitStr)));
      } else {
        r.add(item);
      }
    }
    if (r.isEmpty()) {
      throw new IllegalArgumentException(
          "No values specified for flag " + currentFlag + "\n  " + String
              .join("\n  ", originalArgs));
    }
    return r;
  }

}

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


  public Options(List<String> args) {
    this.args = new LinkedList<>(args);
    originalArgs = args.toArray(new String[0]);
  }

  public RuntimeException unrecognizedFlagException() {
    return new RuntimeException(String.format(""
            + "Unrecognized argument '%s' in args:\n  %s",
        currentFlag, String.join("\n  ", args)));
  }

  public boolean hasMoreFlags() {
    return !args.isEmpty();
  }

  public String nextFlag() {
    currentFlag = args.remove();
    return currentFlag;
  }

  public String getValue() {
    String v = args.remove();
    if (!args.isEmpty() && !args.peek().startsWith("--")) {
      throw new IllegalArgumentException(
          "Got multiple values for single value flag " + currentFlag + "\n  " + String
              .join("\n  ", originalArgs));
    }
    return v;
  }

  public List<String> getList() {
    return getList(null);
  }

  public List<String> getList(String splitStr) {
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

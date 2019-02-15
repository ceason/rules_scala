#!/usr/bin/env bash

echoerr() {
  echo "$@" 1>&2;
}

assert() {
  $@ || (echo "FAILED: $@"; exit 1)
}

contains() {
  grep $@
}

set -e

assert contains "scalarules/test/Bar.class" $1    # Bar.scala
assert contains "scalarules/test/Foo.class" $1    # Foo.java
assert contains "scalarules/test/Baz.class" $1    # Baz.java
assert contains "scalarules/test/FooBar.class" $1 # FooBar.java

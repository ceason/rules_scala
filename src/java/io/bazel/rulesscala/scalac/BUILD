load("//scala:scala.bzl", "scala_library_for_plugin_bootstrapping")
load(
    ":jvm_export_toolchain.bzl",
    _export_scalac_repositories_from_toolchain_to_jvm = "export_scalac_repositories_from_toolchain_to_jvm",
)

_export_scalac_repositories_from_toolchain_to_jvm(
    name = "current_classpath",
    exported_attr = "default_classpath",
    visibility = ["//visibility:public"],
)

_export_scalac_repositories_from_toolchain_to_jvm(
    name = "current_macro_classpath",
    exported_attr = "default_macro_classpath",
    visibility = ["//visibility:public"],
)

_export_scalac_repositories_from_toolchain_to_jvm(
    name = "current_repl_classpath",
    exported_attr = "default_repl_classpath",
    visibility = ["//visibility:public"],
)

java_library(
    name = "options",
    srcs = ["Options.java"],
)

java_library(
    name = "jdeps_enforcer",
    srcs = ["JdepsEnforcer.java"],
    deps = [
        ":options",
        "//src/java/com/google/devtools/build/lib/view/proto:deps",
    ],
)

java_binary(
    name = "jdeps_jar_merger",
    srcs = ["JdepsJarMerger.java"],
    main_class = "io.bazel.rulesscala.scalac.JdepsJarMerger",
    visibility = ["//visibility:public"],
    deps = [
        ":jdeps_enforcer",
        ":options",
        "//src/java/com/google/devtools/build/lib/view/proto:deps",
    ],
)

scala_library_for_plugin_bootstrapping(
    name = "jdeps_plugin",
    srcs = ["JdepsPlugin.scala"],
    resources = ["resources/scalac-plugin.xml"],
    visibility = ["//visibility:public"],
    deps = [
        ":current_repl_classpath",
        ":jdeps_enforcer",
        "//src/java/com/google/devtools/build/lib/view/proto:deps",
    ],
)

java_binary(
    name = "scalac",
    srcs = [
        "@io_bazel_rules_scala//src/java/io/bazel/rulesscala/scalac:scalac_files",
    ],
    javacopts = [
        "-source 1.8",
        "-target 1.8",
    ],
    main_class = "io.bazel.rulesscala.scalac.ScalaCInvoker",
    visibility = ["//visibility:public"],
    deps = [
        ":current_repl_classpath",
        ":options",
        "@io_bazel_rules_scala//src/java/com/google/devtools/build/lib:worker",
        "@io_bazel_rules_scala//src/java/io/bazel/rulesscala/worker",
    ],
)

filegroup(
    name = "scalac_files",
    srcs = [
        "CompileOptions.java",
        "ScalaCInvoker.java",
        "ScalacProcessor.java",
    ],
    visibility = ["//visibility:public"],
)

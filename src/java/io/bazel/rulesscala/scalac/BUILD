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

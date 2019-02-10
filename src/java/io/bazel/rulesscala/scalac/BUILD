load(
    ":jvm_export_toolchain.bzl",
    _export_scalac_repositories_from_toolchain_to_jvm = "export_scalac_repositories_from_toolchain_to_jvm",
)

_export_scalac_repositories_from_toolchain_to_jvm(
    name = "exported_scalac_repositories_from_toolchain_to_jvm",
)

proto_library(
    name = "compile_options_proto",
    srcs = ["compile_options.proto"],
)

java_proto_library(
    name = "java_compile_options_proto",
    visibility = ["//:__subpackages__"],
    deps = [":compile_options_proto"],
)

java_binary(
    name = "compile_options_parser",
    srcs = ["CompileOptionsParser.java"],
    main_class = "io.bazel.rulesscala.scalac.CompileOptionsParser",
    visibility = ["//visibility:public"],
    deps = [
        ":java_compile_options_proto",
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
        ":exported_scalac_repositories_from_toolchain_to_jvm",
        ":java_compile_options_proto",
        "@io_bazel_rules_scala//src/java/com/google/devtools/build/lib:worker",
        "@io_bazel_rules_scala//src/java/io/bazel/rulesscala/jar",
        "@io_bazel_rules_scala//src/java/io/bazel/rulesscala/worker",
        "@scalac_rules_commons_io//jar",
    ],
)

filegroup(
    name = "scalac_files",
    srcs = [
#        "CompileOptions.java",
#        "Resource.java",
        "ScalaCInvoker.java",
        "ScalacProcessor.java",
    ],
    visibility = ["//visibility:public"],
)

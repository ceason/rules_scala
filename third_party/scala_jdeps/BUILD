licenses(["notice"])  # 3-clause BSD

load("//scala:scala.bzl", "scala_library_for_plugin_bootstrapping", "scala_test")

proto_library(
    name = "deps_proto",
    srcs = ["deps.proto"],
)

java_proto_library(
    name = "java_deps_proto",
    deps = [":deps_proto"],
)

scala_library_for_plugin_bootstrapping(
    name = "scala_jdeps",
    srcs = [
        "ScalaJdeps.scala",
        "Config.scala",
    ],
    resources = ["resources/scalac-plugin.xml"],
    visibility = ["//visibility:public"],
    deps = [
        ":java_deps_proto",
        "@com_google_protobuf//:protobuf_java",
        "//external:io_bazel_rules_scala/dependency/scala/scala_compiler",
        "//external:io_bazel_rules_scala/dependency/scala/scala_reflect",
    ],
)

scala_test(
    name = "scala_jdeps_test",
    size = "small",
    srcs = [
        "ScalaJdepsTest.scala",
    ],
    jvm_flags = [
        "-Dplugin.jar.location=$(location :scala_jdeps)",
        "-Dscala.library.location=$(location //external:io_bazel_rules_scala/dependency/scala/scala_library)",
        "-Dapache.commons.jar.location=$(location @org_apache_commons_commons_lang_3_5_without_file//:linkable_org_apache_commons_commons_lang_3_5_without_file)",
    ],
    unused_dependency_checker_mode = "off",
    deps = [
        ":scala_jdeps",
        "//external:io_bazel_rules_scala/dependency/scala/scala_compiler",
        "//external:io_bazel_rules_scala/dependency/scala/scala_library",
        "//external:io_bazel_rules_scala/dependency/scala/scala_reflect",
        "//third_party/utils/src/test:test_util",
        "@org_apache_commons_commons_lang_3_5_without_file//:linkable_org_apache_commons_commons_lang_3_5_without_file",
    ],
)

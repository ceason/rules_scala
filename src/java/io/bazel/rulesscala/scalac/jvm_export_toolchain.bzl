load(
    "@io_bazel_rules_scala//scala:providers.bzl",
    _ScalacProvider = "ScalacProvider",
)

def _export_scalac_repositories_from_toolchain_to_jvm_impl(ctx):
    scalac_provider = ctx.toolchains["@io_bazel_rules_scala//scala:toolchain_type"].scalac_provider_attr[_ScalacProvider]
    deps = getattr(scalac_provider, ctx.attr.exported_attr)
    java_info = java_common.merge([d[JavaInfo] for d in deps])
    return [java_info]

export_scalac_repositories_from_toolchain_to_jvm = rule(
    _export_scalac_repositories_from_toolchain_to_jvm_impl,
    toolchains = ["@io_bazel_rules_scala//scala:toolchain_type"],
    attrs = {
        "exported_attr": attr.string(
            default = "default_repl_classpath",
            values = [
                "default_classpath",
                "default_macro_classpath",
                "default_repl_classpath",
            ],
        ),
    },
)

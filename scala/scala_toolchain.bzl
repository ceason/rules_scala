load(
    "@io_bazel_rules_scala//scala:providers.bzl",
    _ScalacProvider = "ScalacProvider",
)

def _scala_toolchain_impl(ctx):
    toolchain = platform_common.ToolchainInfo(
        scalacopts = ctx.attr.scalacopts,
        scalac_provider_attr = ctx.attr.scalac_provider_attr,
        unused_dependency_checker_mode = ctx.attr.unused_dependency_checker_mode,
        compile_opts_parser = ctx.attr._compile_opts_parser
    )
    return [toolchain]

scala_toolchain = rule(
    _scala_toolchain_impl,
    attrs = {
        "scalacopts": attr.string_list(),
        "scalac_provider_attr": attr.label(
            default = "@io_bazel_rules_scala//scala:scalac_default",
            providers = [_ScalacProvider],
        ),
        "_compile_opts_parser": attr.label(
            executable = True,
            cfg = "host",
            default = Label("//src/java/io/bazel/rulesscala/scalac:compile_options_parser"),
        ),
        "unused_dependency_checker_mode": attr.string(
            default = "off",
            values = ["off", "warn", "error"],
        ),
    },
)

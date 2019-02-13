load(
    "@io_bazel_rules_scala//scala:providers.bzl",
    _ScalaInfo = "ScalaInfo",
    _ScalacProvider = "ScalacProvider",
)

# Returns File (of unpacked directory)
def _unpack_jar(
        ctx,
        # File
        jar = None):  #
    # unpack the jar in a directory of "_scalac/%{jarname}_unpacked"
    # ? also make sure output dir is deleted/clean when unpacking??
    pass





def _scala_toolchain_impl(ctx):
    toolchain = platform_common.ToolchainInfo(
        scalacopts = ctx.attr.scalacopts,
        scalac_provider_attr = ctx.attr.scalac_provider_attr,
        unused_dependency_checker_mode = ctx.attr.unused_dependency_checker_mode,
        scalac = ctx.attr._scalac,
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
        "unused_dependency_checker_mode": attr.string(
            default = "off",
            values = ["off", "warn", "error"],
        ),
        "_scalac": attr.label(
            executable = True,
            cfg = "host",
            default = Label("@io_bazel_rules_scala//src/java/io/bazel/rulesscala/scalac"),
        ),
    },
)

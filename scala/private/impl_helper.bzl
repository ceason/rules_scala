load(":compile.bzl", "compile")
load(":pack_jar.bzl", "pack_jar")

# Does the common recipe, using ctx.attrs directly.
# Returns struct with legacy providers & new provider format.
def impl_helper(
        ctx,

        # depset[File]
        deps_enforcer_ignored_jars = [],

        # bool
        use_ijar = False):
    unused_deps = getattr(ctx.attr, "unused_dependency_checker_mode", None)
    strict_deps = ctx.fragments.java.strict_java_deps
    if strict_deps == "default":
        strict_deps = None

    # TODO: migration for non-JavaInfo plugins

    # compile scala
    scalac_output = ctx.actions.declare_file("%s-scala-class.jar" % ctx.label.name)
    compile(
        ctx,
        source_jars = [f for f in ctx.files.srcs if f.endswith(".srcjar")],
        source_files = [f for f in ctx.files.srcs if not f.endswith(".srcjar")],
        output = scalac_output,
        output_statsfile = ctx.outputs.statsfile,
        output_jdeps = ctx.outputs.jdeps,
        scalac_opts = ctx.attr.scalacopts,
        deps = [d[JavaInfo] for d in ctx.attr.deps],
        plugins = [d[JavaInfo] for d in ctx.attr.plugins],
        unused_deps_mode = unused_deps,
        strict_deps_mode = strict_deps,
        deps_enforcer_ignored_jars = depset(
            transitive = (
                deps_enforcer_ignored_jars or []
            ) + [
                d[JavaInfo].compile_jars
                for d in ctx.attr.unused_dependency_checker_ignored_targets
            ],
        ),
    )

    # maybe compile java
    full_compile_jar = scalac_output  # this might be overridden if we're outputting java too
    java_files = [f for f in ctx.files.srcs if f.endswith(".java")]
    if java_files or ctx.attr.expect_java_output:
        javac_output = ctx.actions.declare_file("%s-java-class.jar" % ctx.label.name)
        java_common.compile(
            ctx,
            source_jars = [f for f in ctx.files.srcs if f.endswith(".srcjar")],
            source_files = java_files,
            output = javac_output,
            javac_opts = ctx.attr.javacopts,
            deps = [d[JavaInfo] for d in ctx.attr.deps] + [
                JavaInfo(compile_jar = scalac_output),
            ],
            java_toolchain = ctx.attr._java_toolchain,
            host_javabase = ctx.attr._host_javabase,
            strict_deps = ctx.fragments.java.strict_java_deps,
        )

        # combine the java and scala compiled jars
        full_compile_jar = ctx.actions.declare_file("%s-class.jar" % ctx.label.name)
        pack_jar(
            ctx,
            output = full_compile_jar,
            jars = [scalac_output, javac_output],
        )

    # pack the compiled jar with resources
    packjar_jars = [full_compile_jar]
    packjar_jars += getattr(ctx.files, "resource_jars", [])
    packjar_kwargs = {}
    if hasattr(ctx.attr, "main_class"):
        packjar_kwargs["main_class"] = ctx.attr.main_class
    if hasattr(ctx.files, "classpath_resources"):
        packjar_kwargs["classpath_resources"] = ctx.files.classpath_resources
    pack_jar(
        ctx,
        output = ctx.outputs.jar,
        jars = packjar_jars,
        resource_strip_prefix = getattr(ctx.attr, "resource_strip_prefix", ""),
        resources = getattr(ctx.files, "resources", []),
        **packjar_kwargs
    )

    # create a srcs jar
    java_common.pack_sources(
        ctx.actions,
        output = ctx.outputs.srcjar,
        sources = [f for f in ctx.files.srcs if not f.endswith(".srcjar")],
        source_jars = [f for f in ctx.files.srcs if f.endswith(".srcjar")],
        java_toolchain = ctx.attr._java_toolchain,
        host_javabase = ctx.attr._host_javabase,
    )

    # create a label-stamped compile_jar (using ijar, if possible)
    compile_jar_tool = java_common.run_ijar if use_ijar else java_common.stamp_jar
    compile_jar = compile_jar_tool(
        ctx.actions,
        jar = full_compile_jar,
        target_label = ctx.label,
        java_toolchain = ctx._java_toolchain,
    )

    java_info = JavaInfo(
        output_jar = ctx.outputs.jar,
        compile_jar = compile_jar,
        source_jar = ctx.outputs.srcjar,
        neverlink = ctx.attr.neverlink,
        deps = [d[JavaInfo] for d in ctx.attr.deps],
        exports = [d[JavaInfo] for d in ctx.attr.exports],
        runtime_deps = [d[JavaInfo] for d in ctx.attr.runtime_deps],
        jdeps = ctx.outputs.jdeps,
    )

    # create the deploy jar
    pack_jar(
        ctx,
        output = ctx.outputs.deploy_jar,
        transitive_jars = java_info.transitive_runtime_jars,
        main_class = getattr(ctx.attr, "main_class", None),
    )

    # not sure making the manifest available as a separate thing makes sense,
    # but doing it anyway to maintain existing behavior
    ctx.actions.run_shell(
        inputs = [ctx.outputs.jar],
        outputs = [ctx.outputs.manifest],
        command = """#!/usr/bin/env bash
        set -euo pipefail
        jar=$1; shift
        out=$1; shift
        unzip -p "$jar" META-INF/MANIFEST.MF > "$out"
        """,
    )

    default_info = DefaultInfo(
        files = depset(direct = [ctx.outputs.jar]),
        runfiles = ctx.runfiles(collect_default = True),
    )
    return struct(
        java_info = java_info,
        default_info = default_info,
        providers = [
            java_info,
            default_info,
        ],
    )

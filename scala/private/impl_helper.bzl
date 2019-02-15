load(":compile.bzl", "compile")
load(":pack_jar.bzl", "pack_jar")
load(":launcher.bzl", "launcher")

# Does the common recipe, using ctx.attrs directly.
# Returns struct with legacy providers & new provider format.
def impl_helper(
        ctx,

        # depset[File]
        deps_enforcer_ignored_jars = None,

        # list[JavaInfo]
        extra_deps = [],
        extra_runtime_deps = [],

        # list[String]
        extra_jvm_flags = [],
        extra_args = [],

        # File
        output_executable = None,
        output_statsfile = None,
        output_deploy_jar = None,
        output_manifest = None,
        output_jar = None,
        output_jdeps = None,

        # String
        executable_wrapper_preamble = None,
        override_main_class = None,

        # bool
        use_ijar = False):
    tc = ctx.toolchains["@io_bazel_rules_scala//scala:toolchain_type"]
    unused_deps = getattr(ctx.attr, "unused_dependency_checker_mode", None)
    main_class = override_main_class or getattr(ctx.attr, "main_class", None)
    strict_deps = ctx.fragments.java.strict_java_deps
    if strict_deps == "default":
        strict_deps = None

    deps = [tc.runtime] + extra_deps + [
        d[JavaInfo]
        for d in ctx.attr.deps
    ]

    # TODO: migration for non-JavaInfo plugins

    # compile scala
    scalac_output = ctx.actions.declare_file("%s-scala-class.jar" % output_jar.basename[:-len(".jar")])
    compile(
        ctx,
        source_jars = [f for f in ctx.files.srcs if f.path.endswith(".srcjar")],
        source_files = [f for f in ctx.files.srcs if not f.path.endswith(".srcjar")],
        output = scalac_output,
        output_statsfile = output_statsfile,
        output_jdeps = output_jdeps,
        scalac_opts = ctx.attr.scalacopts,
        deps = deps,
        plugins = [d[JavaInfo] for d in ctx.attr.plugins],
        unused_deps_mode = unused_deps,
        strict_deps_mode = strict_deps,
        deps_enforcer_ignored_jars = depset(
            transitive = (
                [deps_enforcer_ignored_jars] if deps_enforcer_ignored_jars else []
            ) + [
                d[JavaInfo].compile_jars
                for d in getattr(ctx.attr, "unused_dependency_checker_ignored_targets", [])
            ],
        ),
    )

    # maybe compile java
    full_compile_jar = scalac_output  # this might be overridden if we're outputting java too
    java_files = [f for f in ctx.files.srcs if f.path.endswith(".java")]
    if java_files or ctx.attr.expect_java_output:
        javac_output = ctx.actions.declare_file("%s-java-class.jar" % output_jar.basename[:-len(".jar")])
        java_common.compile(
            ctx,
            source_jars = [f for f in ctx.files.srcs if f.path.endswith(".srcjar")],
            source_files = java_files,
            output = javac_output,
            javac_opts = ctx.attr.javacopts,
            deps = deps + [JavaInfo(compile_jar = scalac_output, output_jar = scalac_output)],
            java_toolchain = ctx.attr._java_toolchain,
            host_javabase = ctx.attr._host_javabase,
            strict_deps = ctx.fragments.java.strict_java_deps,
        )

        # combine the java and scala compiled jars
        full_compile_jar = ctx.actions.declare_file("%s-class.jar" % output_jar.basename[:-len(".jar")])
        pack_jar(
            ctx,
            output = full_compile_jar,
            jars = [scalac_output, javac_output],
        )

    # pack the compiled jar with resources
    pack_jar(
        ctx,
        output = output_jar,
        jars = [full_compile_jar] + getattr(ctx.files, "resource_jars", []),
        resource_strip_prefix = getattr(ctx.attr, "resource_strip_prefix", ""),
        resources = getattr(ctx.files, "resources", []),
        classpath_resources = getattr(ctx.files, "classpath_resources", []),
    )

    # create a srcs jar
    srcjar = java_common.pack_sources(
        ctx.actions,
        output_jar = output_jar,
        sources = [f for f in ctx.files.srcs if not f.path.endswith(".srcjar")],
        source_jars = [f for f in ctx.files.srcs if f.path.endswith(".srcjar")],
        java_toolchain = ctx.attr._java_toolchain,
        host_javabase = ctx.attr._host_javabase,
    )

    # create a label-stamped compile_jar (using ijar, if possible)
    if use_ijar:
        compile_jar = java_common.run_ijar(ctx.actions, jar = full_compile_jar, target_label = ctx.label, java_toolchain = ctx.attr._java_toolchain)
    else:
        compile_jar = java_common.stamp_jar(ctx.actions, jar = full_compile_jar, target_label = ctx.label, java_toolchain = ctx.attr._java_toolchain)

    java_info = JavaInfo(
        output_jar = output_jar,
        compile_jar = compile_jar,
        source_jar = srcjar,
        neverlink = getattr(ctx.attr, "neverlink", False),
        deps = deps,
        exports = [d[JavaInfo] for d in getattr(ctx.attr, "exports", [])],
        runtime_deps = [d[JavaInfo] for d in ctx.attr.runtime_deps] + extra_runtime_deps,
        jdeps = output_jdeps,
    )

    # create the deploy jar
    if output_deploy_jar:
        pack_jar(
            ctx,
            output = output_deploy_jar,
            transitive_jars = java_info.transitive_runtime_jars,
            main_class = main_class,
            compression = True,
        )

    # not sure making the manifest available as a separate thing makes sense,
    # but doing it anyway to maintain existing behavior
    if output_manifest:
        ctx.actions.run_shell(
            inputs = [output_jar],
            outputs = [output_manifest],
            command = """#!/usr/bin/env bash
            set -euo pipefail
            jar=$1; shift
            out=$1; shift
            unzip -p "$jar" META-INF/MANIFEST.MF > "$out"
            """,
        )

    outputs = [output_jar]
    executable_runfiles = None
    if output_executable:
        outputs += [output_executable]
        executable_runfiles = launcher(
            ctx,
            output = output_executable,
            classpath_jars = java_info.transitive_runtime_jars,
            main_class = main_class,
            extra_jvm_flags = extra_jvm_flags,
            extra_args = extra_args,
            wrapper_preamble = executable_wrapper_preamble,
        )

    default_info = DefaultInfo(
        files = depset(direct = outputs),
        runfiles = ctx.runfiles(collect_default = True, transitive_files = executable_runfiles),
        executable = output_executable,
    )
    return struct(
        java = java_info,
        scala = java_info,
        providers = [
            java_info,
            default_info,
        ],
    )

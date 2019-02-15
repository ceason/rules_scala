load(":compile.bzl", "compile", "scalac")
load(":pack_jar.bzl", "pack_jar")
load(":launcher.bzl", "launcher")

# convert JavaInfo to a backward compatible 'scala' legacy provider
def _scala_provider_from(java_info, output_jar):
    return struct(
        annotation_processing = java_info.annotation_processing,
        compilation_info = java_info.compilation_info,
        compile_jars = java_info.compile_jars,
        full_compile_jars = java_info.full_compile_jars,
        runtime_output_jars = java_info.runtime_output_jars,
        source_jars = java_info.source_jars,
        transitive_compile_time_jars = java_info.transitive_compile_time_jars,
        transitive_deps = java_info.transitive_deps,
        transitive_exports = java_info.transitive_exports,
        transitive_runtime_deps = java_info.transitive_runtime_deps,
        transitive_runtime_jars = java_info.transitive_runtime_jars,
        transitive_source_jars = java_info.transitive_source_jars,
        outputs = struct(
            jars = java_info.outputs.jars,
            jdeps = java_info.outputs.jdeps,
            native_headers = java_info.outputs.native_headers,
            class_jar = output_jar,
        ),
    )

# Does the common recipe, using ctx.attrs directly.
# Returns struct with legacy providers & new provider format.
def impl_helper(
        ctx,

        # depset[File]
        deps_enforcer_ignored_jars = None,

        # list[JavaInfo]
        extra_exports = [],
        extra_deps = [],
        extra_runtime_deps = [],

        # list[String]
        extra_jvm_flags = [],
        extra_args = [],

        # list[File]
        extra_srcs = [],

        # File
        output_executable = None,
        output_statsfile = None,
        output_deploy_jar = None,
        output_manifest = None,
        output_jar = None,

        # String
        executable_wrapper_preamble = None,
        override_main_class = None,
        override_strict_deps = None,
        override_unused_deps = None,

        # bool
        use_ijar = False):
    tc = ctx.toolchains["@io_bazel_rules_scala//scala:toolchain_type"]
    unused_deps = override_unused_deps or getattr(ctx.attr, "unused_dependency_checker_mode", None)
    main_class = override_main_class or getattr(ctx.attr, "main_class", None)
    strict_deps = override_strict_deps or ctx.fragments.java.strict_java_deps
    if strict_deps == "default":
        strict_deps = None

    source_files = []
    source_jars = []
    for f in getattr(ctx.files, "srcs", []) + extra_srcs:
        if f.extension in ["java", "scala"]:
            source_files += [f]
        elif f.extension == "srcjar":
            source_jars += [f]
        else:
            fail("Invalid file type, wanted '.java .scala .srcjar' but got '%s'" % f.basename)
    deps = [tc.runtime] + extra_deps + [d[JavaInfo] for d in getattr(ctx.attr, "deps", [])]
    exports = [d[JavaInfo] for d in getattr(ctx.attr, "exports", [])] + extra_exports
    runtime_deps = [d[JavaInfo] for d in getattr(ctx.attr, "runtime_deps", [])] + extra_runtime_deps
    resource_jars = getattr(ctx.files, "resource_jars", [])
    resource_strip_prefix = getattr(ctx.attr, "resource_strip_prefix", "")
    resources = getattr(ctx.files, "resources", [])
    classpath_resources = getattr(ctx.files, "classpath_resources", [])

    if source_files or source_jars:
        # there are srcs, so compile them
        java_info = compile(
            ctx,
            source_jars = source_jars,
            source_files = source_files,
            output = output_jar,
            output_statsfile = output_statsfile,
            deps = deps,
            runtime_deps = runtime_deps,
            exports = exports,
            neverlink = getattr(ctx.attr, "neverlink", False),
            scalac_opts = getattr(ctx.attr, "scalacopts", []),
            plugins = [d[JavaInfo] for d in getattr(ctx.attr, "plugins", [])],
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
            resource_jars = getattr(ctx.files, "resource_jars", []),
            resource_strip_prefix = getattr(ctx.attr, "resource_strip_prefix", ""),
            resources = getattr(ctx.files, "resources", []),
            classpath_resources = getattr(ctx.files, "classpath_resources", []),
            use_ijar = use_ijar
        )
    elif resource_jars or resources or classpath_resources:
        # there are only resources, so pack them into a jar
        pack_jar(
            ctx,
            output = output_jar,
            deploy_manifest_lines = ["Target-Label: %s" % str(ctx.label)],
            resources = resources,
            classpath_resources = classpath_resources,
            jars = resource_jars,
            resource_strip_prefix = resource_strip_prefix,
        )
        ctx.actions.write(output_statsfile, "")
        java_info = JavaInfo(
            output_jar = output_jar,
            compile_jar = output_jar,
            deps = deps,
            runtime_deps = runtime_deps,
            exports = exports,
        )
    else:
        # there's no content for the jar, so make an empty jar
        pack_jar(ctx, output = output_jar, deploy_manifest_lines = [
            "Target-Label: %s" % str(ctx.label),
        ])
        ctx.actions.write(output_statsfile, "")
        java_info = JavaInfo(
            output_jar = output_jar,
            compile_jar = output_jar,
            deps = deps,
            runtime_deps = runtime_deps,
            exports = exports,
        )

    # TODO: migration for non-JavaInfo plugins

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
        scala = _scala_provider_from(java_info, output_jar),
        providers = [
            java_info,
            default_info,
        ],
    )

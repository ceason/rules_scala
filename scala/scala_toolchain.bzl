load(
    "@io_bazel_rules_scala//scala:providers.bzl",
    _ScalaInfo = "ScalaInfo",
    _ScalacProvider = "ScalacProvider",
)

def _compile(
        ctx,

        # bool
        use_ijar = False,
        neverlink = False,

        # string
        main_class = None,
        resource_strip_prefix = None,

        # list[File]
        source_jars = [],
        source_files = [],
        resources = [],
        classpath_resources = [],

        # File
        output = None,
        output_source_jar = None,
        output_statsfile = None,
        output_jdeps = None,

        # list[string]
        scalac_opts = [],
        deps_enforcer_ignored_jars = [],

        # list[JavaInfo]
        deps = [],
        exports = [],
        plugins = [],

        # off/error/warn
        strict_deps_mode = None,
        unused_deps_mode = None):
    if output_jdeps and not hasattr(ctx.attr, "_scalac_jdeps_plugin"):
        fail("output_jdeps requires the implicit attr _scalac_jdeps_plugin")

    tc = ctx.toolchains["@io_bazel_rules_scala//scala:toolchain_type"]

    # accumulate args, inputs & outputs for compilation
    compile_inputs = []
    compile_outputs = []
    args = ctx.actions.args()
    args.use_param_file("@%s", use_always = True)  # required for 'worker' strategy
    args.set_param_file_format("multiline")

    # do this stuff if jdeps plugin is present
    if hasattr(ctx.attr, "_scalac_jdeps_plugin"):
        compile_outputs += [jdeps_output]
        plugins = plugins + [ctx.attr._scalac_jdeps_plugin[JavaInfo]]
        scalac_opts = scalac_opts + [
            "-P:scala-jdeps:output:" + jdeps_output.path,
            "-P:scala-jdeps:strict-deps-mode:" + (strict_deps_mode or tc.default_strict_deps_mode),
            "-P:scala-jdeps:unused-deps-mode:" + (unused_deps_mode or tc.default_unused_deps_mode),
            "-P:scala-jdeps:deps-enforcer-ignored-jars:" + ",".join(deps_enforcer_ignored_jars + tc.deps_enforcer_ignored_jars),
        ]

    # Manifest

    # Files
    args.add_joined(source_files, format_joined = "Files: %s", join_with = ",")
    input += source_files

    # SourceJars
    args.add_joined(source_jars, format_joined = "SourceJars: %s", join_with = ",")
    input += source_jars

    # DirectJars
    direct_jars = depset(transitive = [d.compile_jars for d in deps])
    args.add_joined(direct_jars, format_joined = "DirectJars: %s", join_with = ",")
    input += [direct_jars]

    # Classpath
    compiler_classpath_jars = depset(transitive = [direct_jars] + [d.transitive_compile_time_jars for d in deps])
    args.add_joined(compiler_classpath_jars, format_joined = "Classpath: %s", join_with = ctx.configuration.host_path_separator)
    compile_inputs += [compiler_classpath_jars]

    # Plugins
    compiler_plugin_jars = depset(
        direct = [j for j in d.output.jars for d in plugins],
        transitive = [d.transitive_runtime_jars for d in plugins],
    )
    args.add_joined(compiler_plugin_jars, format_joined = "Plugins: %s", join_with = ",")
    compile_inputs += [compiler_plugin_jars]

    # ScalacOpts
    args.add_joined(tc.scalacopts + scalac_opts, format_joined = "ScalacOpts: %s", join_with = ",")

    # CurrentTarget
    args.add(str(ctx.label), format = "CurrentTarget: %s")

    # compilation outputs
    args.add(output, format = "JarOutput: %s")
    compile_outputs += [output]
    if output_statsfile:
        args.add(output_statsfile, format = "StatsfileOutput: %s")
        compile_outputs += [output_statsfile]

    # compile this shiz
    # invoke the compiler with the args/opts file
    ctx.actions.run(
        inputs = depset(
            direct = [i for i in compile_inputs if type(i) != "depset"],
            transitive = [i for i in compile_inputs if type(i) == "depset"],
        ),
        outputs = compile_outputs,
        executable = tc.scalac.files_to_run.executable,
        #        input_manifests = scalac_input_manifests,
        tools = tc.scalac.default_runfiles.files,
        mnemonic = "Scalac",
        progress_message = "scala %s" % ctx.label,
        execution_requirements = {"supports-workers": "1"},
        #  when we run with a worker, the `@argfile.path` is removed and passed
        #  line by line as arguments in the protobuf. In that case,
        #  the rest of the arguments are passed to the process that
        #  starts up and stays resident.

        # In either case (worker or not), they will be jvm flags which will
        # be correctly handled since the executable is a jvm app that will
        # consume the flags on startup.
        arguments = [
            "--jvm_flag=%s" % ctx.expand_location(f, ctx.attr.data)
            for f in ctx.attr.scalac_jvm_flags
        ] + [args],
    )

    return JavaInfo(
        output_jar = output,
#        compile_jar = output,
        source_jar = "???",
#        neverlink = neverlink,
#        deps = deps,
#        runtime_deps = "???",
#        exports = "???",
        jdeps = output_jdeps,
    )

def _scala_toolchain_impl(ctx):
    default_strict_deps = ctx.fragments.java.strict_java_deps
    if default_strict_deps == "default":
        default_strict_deps = "off"
    if "strict_scala_deps" in ctx.var:
        default_strict_deps = ctx.var["strict_scala_deps"]

    default_unused_deps = "warn"
    if "unused_scala_deps" in ctx.var:
        default_unused_deps = ctx.var["unused_scala_deps"]

    toolchain = platform_common.ToolchainInfo(
        scalacopts = ctx.attr.scalacopts,
        scalac_provider_attr = ctx.attr.scalac_provider_attr,
        unused_dependency_checker_mode = ctx.attr.unused_dependency_checker_mode,
        compile = _compile,
        default_strict_deps_mode = default_strict_deps,
        default_unused_deps_mode = "warn",
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

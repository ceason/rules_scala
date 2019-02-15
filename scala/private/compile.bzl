load(":pack_jar.bzl", "pack_jar")

# helps filter inputs to scalac (eg unneeded files from extracted srcjars)
def _filter_scalac_inputs(file):
    if file.extension in ["scala", "java"]:
        return file.path
    else:
        return []

# Low leverl compiler wrapper for scalac
def scalac(
        ctx,

        # list[File]
        source_jars = [],
        source_files = [],

        # File
        output = None,
        output_statsfile = None,
        output_jdeps = None,

        # list[string]
        scalac_opts = [],

        # depset[File]
        deps_enforcer_ignored_jars = None,

        # list[JavaInfo]
        deps = [],
        plugins = [],

        # off/error/warn
        strict_deps_mode = None,
        unused_deps_mode = None):
    tc = ctx.toolchains["@io_bazel_rules_scala//scala:toolchain_type"]

    # inpuit validation
    if output_jdeps and not hasattr(ctx.attr, "_scalac_jdeps_plugin"):
        fail("output_jdeps requires the implicit attr _scalac_jdeps_plugin")

    # defaults for strict and unused deps
    strict_deps_mode = strict_deps_mode or "error"
    unused_deps_mode = unused_deps_mode or "warn"

    # accumulate args, inputs & outputs for compilation
    compile_inputs = []
    compile_outputs = []
    args = ctx.actions.args()
    args.use_param_file("@%s", use_always = True)  # required for 'worker' strategy
    args.set_param_file_format("multiline")

    # scalacopts
    args.add_all("--scalac_opts", scalac_opts)

    # classpath
    classpath_jars = depset(transitive = [d.transitive_compile_time_jars for d in deps])
    args.add("--scalac_opts", "-classpath")
    args.add_joined(
        "--scalac_opts",
        classpath_jars,
        join_with = ctx.configuration.host_path_separator,
    )
    compile_inputs += [classpath_jars]

    # srcs
    args.add_all("--sources", source_files)
    compile_inputs += source_files

    # unpack srcjars if there are any
    #  each jar is unpacked to directory of "_scalac/%{jarname}_unpacked"
    # ? also make sure output dir is deleted/clean when unpacking??
    for srcjar in source_jars:
        srcjar_dir = ctx.actions.declare_directory("_scalac/%s_unpacked" % srcjar.basename, sibling = srcjar)
        ctx.actions.run(
            inputs = [srcjar],
            outputs = [srcjar_dir],
            executable = ctx.executable._zipper,
            arguments = ["x", srcjar.path, "-d", srcjar_dir.path],
        )
        args.add_all("--sources", [srcjar_dir], expand_directories = True, map_each = _filter_scalac_inputs)
        compile_inputs += [srcjar_dir]

    # add provided plugins
    for p in plugins:
        compile_inputs += [p.transitive_runtime_jars]
        args.add_joined(
            "--scalac_opts",
            p.transitive_runtime_jars,
            join_with = ctx.configuration.host_path_separator,
            format_joined = "-Xplugin:%s",
        )

    # optionally add jdeps plugin & opts
    if output_jdeps:
        jdeps_jars = ctx.attr._scalac_jdeps_plugin[JavaInfo].transitive_runtime_jars
        compile_inputs += [jdeps_jars]
        compile_outputs += [output_jdeps]
        args.add("--scalac_opts", "-Xplugin-require:scala-jdeps")
        args.add_joined(
            "--scalac_opts",
            jdeps_jars,
            join_with = ctx.configuration.host_path_separator,
            format_joined = "-Xplugin:%s",
        )
        ignored_jars = [deps_enforcer_ignored_jars, tc.deps_enforcer_ignored_jars]
        ignored_jars = [j for j in ignored_jars if j != None]  # filter empty
        args.add_joined(
            "--scalac_opts",
            depset(transitive = ignored_jars),
            join_with = ctx.configuration.host_path_separator,
            format_joined = "-P:scala-jdeps:ignored-jars:%s",
        )
        args.add_joined(
            "--scalac_opts",
            classpath_jars,
            join_with = ctx.configuration.host_path_separator,
            format_joined = "-P:scala-jdeps:classpath-jars:%s",
        )
        direct_jars = depset(transitive = [d.compile_jars for d in deps])
        compile_inputs += [direct_jars]
        args.add_joined(
            "--scalac_opts",
            direct_jars,
            join_with = ctx.configuration.host_path_separator,
            format_joined = "-P:scala-jdeps:direct-jars:%s",
        )
        args.add("--scalac_opts", output_jdeps, format = "-P:scala-jdeps:output:%s")
        args.add("--scalac_opts", str(ctx.label), format = "-P:scala-jdeps:current-target:%s")
        args.add("--scalac_opts", strict_deps_mode, format = "-P:scala-jdeps:strict-deps-mode:%s")
        args.add("--scalac_opts", unused_deps_mode, format = "-P:scala-jdeps:unused-deps-mode:%s")

    # compilation outputs
    args.add("--scalac_opts", "-d")
    args.add("--scalac_opts", output)
    compile_outputs += [output]
    if output_statsfile:
        args.add("--output_statsfile", output_statsfile)
        compile_outputs += [output_statsfile]

    # compile this shiz
    # invoke the compiler with the args/opts file
    tools, _, input_manifests = ctx.resolve_command(tools = [ctx.attr._scalac])
    ctx.actions.run(
        inputs = depset(
            direct = [i for i in compile_inputs if type(i) != "depset"],
            transitive = [i for i in compile_inputs if type(i) == "depset"],
        ),
        outputs = compile_outputs,
        executable = ctx.attr._scalac.files_to_run.executable,
        input_manifests = input_manifests,
        tools = tools,
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
            for f in getattr(ctx.attr, "scalac_jvm_flags", [])
        ] + [args],
    )

# Compiles srcs & returns a JavaInfo provider
def compile(
        ctx,

        # File
        output = None,
        output_statsfile = None,

        # list[String]
        scalac_opts = [],

        # list[File]
        resource_jars = [],
        classpath_resources = [],
        resources = [],
        source_jars = [],
        source_files = [],

        # String
        resource_strip_prefix = None,

        # list[JavaInfo]
        deps = [],
        runtime_deps = [],
        exports = [],

        # bool
        neverlink = False,
        use_ijar = False,

        # kwargs are passed to 'scalac()'
        **kwargs):
    output_jdeps = None
    if "output_jdeps" in kwargs:
        fail("Cannot set reserved kwarg 'output_jdeps' in compile()")
    if hasattr(ctx.attr, "_scalac_jdeps_plugin"):
        output_jdeps = ctx.actions.declare_file("%s.jdeps" % output.basename[:-len(".jar")], sibling = output)

    # compile scala
    scalac_output = ctx.actions.declare_file("%s-class.jar" % output.basename[:-len(".jar")], sibling = output)
    scalac(
        ctx,
        source_jars = source_jars,
        source_files = source_files,
        output = scalac_output,
        output_statsfile = output_statsfile,
        output_jdeps = output_jdeps,
        deps = deps,
        **kwargs
    )

    # maybe compile java, unless it's been explicitly turned off
    java_files = [f for f in source_files if f.extension == "java"]
    if (java_files or source_jars) and getattr(ctx.attr, "expect_java_output", True):
        javac_output = ctx.actions.declare_file("%s_java-class.jar" % output.basename[:-len(".jar")], sibling = output)
        java_common.compile(
            ctx,
            source_jars = source_jars,
            source_files = java_files,
            output = javac_output,
            javac_opts = getattr(ctx.attr, "javacopts", []),
            deps = deps + [JavaInfo(compile_jar = scalac_output, output_jar = scalac_output)],
            java_toolchain = ctx.attr._java_toolchain,
            host_javabase = ctx.attr._host_javabase,
            strict_deps = ctx.fragments.java.strict_java_deps,
        )

        # combine the java and scala compiled jars
        full_compile_jar = ctx.actions.declare_file("%s-class.jar" % output.basename[:-len(".jar")], sibling = output)
        pack_jar(
            ctx,
            output = full_compile_jar,
            jars = [scalac_output, javac_output],
        )
    else:
        full_compile_jar = scalac_output

    # pack the compiled jar with resources
    pack_jar(
        ctx,
        output = output,
        jars = [full_compile_jar] + resource_jars,
        resource_strip_prefix = resource_strip_prefix,
        resources = resources,
        classpath_resources = classpath_resources,
    )

    # create a srcs jar
    srcjar = java_common.pack_sources(
        ctx.actions,
        output_jar = output,
        sources = source_files,
        source_jars = source_jars,
        java_toolchain = ctx.attr._java_toolchain,
        host_javabase = ctx.attr._host_javabase,
    )

    # create a label-stamped compile_jar (using ijar, if possible)
    if use_ijar:
        compile_jar = java_common.run_ijar(ctx.actions, jar = full_compile_jar, target_label = ctx.label, java_toolchain = ctx.attr._java_toolchain)
    else:
        compile_jar = java_common.stamp_jar(ctx.actions, jar = full_compile_jar, target_label = ctx.label, java_toolchain = ctx.attr._java_toolchain)

    return JavaInfo(
        output_jar = output,
        compile_jar = compile_jar,
        source_jar = srcjar,
        neverlink = neverlink,
        deps = deps,
        exports = exports,
        runtime_deps = runtime_deps,
        jdeps = output_jdeps,
    )

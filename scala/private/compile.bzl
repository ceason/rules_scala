load(":pack_jar.bzl", "pack_jar")
load(":jdeps_plugin.bzl", "add_scalac_jdeps_plugin_args", "has_jdeps_plugin", "merge_jdeps_jars")

def _filter_scalac_inputs(file):
    """helps filter inputs to scalac (eg unneeded files from extracted srcjars)"""
    if file.extension in ["scala", "java"]:
        return file.path
    return []

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

        # list[JavaInfo]
        deps = [],
        plugins = [],

        # off/error/warn
        strict_deps_mode = None,
        unused_deps_mode = None):
    """Low level compiler wrapper for scalac"""
    tc = ctx.toolchains["@io_bazel_rules_scala//scala:toolchain_type"]

    # get implicit compile/runtime jars for the rule
    implicit_deps = [d[JavaInfo] for d in ctx.attr._scala_toolchain]

    # accumulate args, inputs & outputs for compilation
    compile_inputs = []
    compile_outputs = []
    args = ctx.actions.args()
    args.use_param_file("@%s", use_always = True)  # required for 'worker' strategy
    args.set_param_file_format("multiline")

    if getattr(ctx.attr, "print_compile_time", False):
        args.add("--print_compile_time")

    # scalacopts
    args.add_all("--scalac_opts", scalac_opts)

    # classpath
    classpath_jars = depset(transitive = [
        d.transitive_compile_time_jars
        for d in implicit_deps + deps
    ])
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
        jdeps_jars = add_scalac_jdeps_plugin_args(
            ctx,
            args,
            strict_deps_mode = strict_deps_mode,
            unused_deps_mode = unused_deps_mode,
            output_jdeps = output_jdeps,
            deps = deps,
            implicit_deps = implicit_deps,
        )
        compile_inputs += [jdeps_jars]
        compile_outputs += [output_jdeps]

    # compilation outputs
    args.add("--scalac_opts", "-d")
    args.add("--scalac_opts", output)
    compile_outputs += [output]
    if output_statsfile:
        args.add("--output_statsfile", output_statsfile)
        compile_outputs += [output_statsfile]

    # compile this stuff
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
            "--jvm_flag=%s" % ctx.expand_location(f, getattr(ctx.attr, "data", []))
            for f in getattr(ctx.attr, "scalac_jvm_flags", [])
        ] + [args],
    )
    return

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
        unused_deps_mode = None,
        strict_deps_mode = None,

        # list[JavaInfo]
        deps = [],
        runtime_deps = [],
        exports = [],

        # bool
        neverlink = False,
        use_ijar = False,

        # kwargs are passed to 'scalac()'
        **kwargs):
    """ Compiles srcs & returns a JavaInfo provider"""
    if "output_jdeps" in kwargs:
        fail("Cannot set reserved kwarg 'output_jdeps' in compile()")

    # action inputs (& conditions determining which actions are necessary)
    implicit_deps = [d[JavaInfo] for d in ctx.attr._scala_toolchain]
    java_files = [f for f in source_files if f.extension == "java"]
    scala_files = [f for f in source_files if f.extension == "scala"]
    COMPILE_JAVA = bool(java_files or source_jars) and getattr(ctx.attr, "expect_java_output", True)
    COMPILE_SCALA = bool(scala_files or source_jars)
    COMPILE_MIXED = COMPILE_SCALA and COMPILE_JAVA

    # Files which will (maybe) be produced by actions
    output_classjar = ctx.actions.declare_file("%s-class.jar" % output.basename[:-len(".jar")], sibling = output)
    output_jdeps = None
    scalac_classjar = None
    scalac_jdeps = None
    javac_classjar = None
    javac_jdeps = None

    # make language-specific classjars if we're compiling mixed-mode
    if COMPILE_MIXED:
        javac_classjar = ctx.actions.declare_file("%s-java-class.jar" % output.basename[:-len(".jar")], sibling = output)
        scalac_classjar = ctx.actions.declare_file("%s-scala-class.jar" % output.basename[:-len(".jar")], sibling = output)
    elif COMPILE_SCALA:
        scalac_classjar = output_classjar
    elif COMPILE_JAVA:
        javac_classjar = output_classjar
    else:
        fail("Must provide either java or scala srcs.")
    if not COMPILE_SCALA:
        ctx.actions.write(output_statsfile, "")

    # compile srcs as necessary
    if COMPILE_SCALA:
        if has_jdeps_plugin(ctx):
            scalac_jdeps = ctx.actions.declare_file("%s.jdeps" % scalac_classjar.basename[:-len("-class.jar")], sibling = scalac_classjar)
        scalac(
            ctx,
            source_jars = source_jars,
            source_files = scala_files + java_files,
            output = scalac_classjar,
            output_statsfile = output_statsfile,
            output_jdeps = scalac_jdeps,
            deps = deps,
            unused_deps_mode = "off" if COMPILE_MIXED else unused_deps_mode,
            strict_deps_mode = "off" if COMPILE_MIXED else strict_deps_mode,
            **kwargs
        )
    if COMPILE_JAVA:
        java_compile_deps = implicit_deps + deps
        if scalac_classjar:
            java_compile_deps += [JavaInfo(compile_jar = scalac_classjar, output_jar = scalac_classjar)]
        javac_jdeps = java_common.compile(
            ctx,
            source_jars = source_jars,
            source_files = java_files,
            output = javac_classjar,
            javac_opts = [
                ctx.expand_location(s, getattr(ctx.attr, "data", []))
                for s in getattr(ctx.attr, "javacopts", []) +
                         getattr(ctx.attr, "javac_jvm_flags", []) +
                         java_common.default_javac_opts(ctx, java_toolchain_attr = "_java_toolchain")
            ],
            deps = java_compile_deps,
            java_toolchain = ctx.attr._java_toolchain,
            host_javabase = ctx.attr._host_javabase,
            strict_deps = "off" if COMPILE_MIXED else ctx.fragments.java.strict_java_deps,
        ).outputs.jdeps

    # merge jars+jdeps if we compiled both java & scala
    if COMPILE_MIXED:
        jdeps_to_merge = []
        if scalac_jdeps and javac_jdeps:
            jdeps_to_merge += [scalac_jdeps, javac_jdeps]
            output_jdeps = ctx.actions.declare_file("%s.jdeps" % output.basename[:-len(".jar")], sibling = output)
        merge_jdeps_jars(
            ctx,
            output = output_classjar,
            output_jdeps = output_jdeps,
            jars = [javac_classjar, scalac_classjar],
            jdeps = jdeps_to_merge,
            unused_deps_mode = unused_deps_mode,
            strict_deps_mode = strict_deps_mode,
            deps = deps,
            implicit_deps = implicit_deps,
        )
    elif COMPILE_JAVA:
        output_jdeps = javac_jdeps
    elif COMPILE_SCALA:
        output_jdeps = scalac_jdeps
    else:
        fail("Unreachable.")

    # pack the compiled jar with resources
    pack_jar(
        ctx,
        output = output,
        jars = [output_classjar] + resource_jars,
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

    # create a label-stamped compile_jar (using ijar, if allowed)
    if use_ijar:
        compile_jar = java_common.run_ijar(ctx.actions, jar = output_classjar, target_label = ctx.label, java_toolchain = ctx.attr._java_toolchain)
    else:
        compile_jar = java_common.stamp_jar(ctx.actions, jar = output_classjar, target_label = ctx.label, java_toolchain = ctx.attr._java_toolchain)

    return JavaInfo(
        output_jar = output,
        compile_jar = compile_jar,
        source_jar = srcjar,
        neverlink = neverlink,
        deps = implicit_deps + deps,
        exports = exports,
        runtime_deps = runtime_deps,
        jdeps = output_jdeps,
    )

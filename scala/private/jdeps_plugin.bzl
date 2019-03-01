jdeps_plugin_attrs = {
    "_scalac_jdeps_plugin": attr.label(
        default = Label("//src/java/io/bazel/rulesscala/scalac:jdeps_plugin"),
        providers = [[JavaInfo]],
    ),
    "_jdeps_jar_merger": attr.label(
        default = Label("//src/java/io/bazel/rulesscala/scalac:jdeps_jar_merger"),
        executable = True,
        cfg = "host",
    ),
}

_AspectInfo = provider(
    fields = {
        "direct_jars_from_exports": "depset[File] of direct jars from exports",
        "aliased_labels": "depset[string] of labels formatted as '<label_alias>::<label>[::<label>...]'",
    },
)

# ':' is reserved & therefore won't collide
_LABEL_DELIMITER = "::"

def _default_unused_deps(ctx):
    # use rule-configured setting (if present)
    if getattr(ctx.attr, "unused_dependency_checker_mode", None):
        return ctx.attr.unused_dependency_checker_mode

    # "--define unused_scala_deps=..." flag
    if "unused_scala_deps" in ctx.var:
        return ctx.var["unused_scala_deps"]

    # fall back to toolchain default
    tc = ctx.toolchains["@io_bazel_rules_scala//scala:toolchain_type"]
    return tc.unused_dependency_checker_mode

def _default_strict_deps(ctx):
    # "--define strict_scala_deps=..." flag takes precedence
    if "strict_scala_deps" in ctx.var:
        return ctx.var["strict_scala_deps"]

    # fall back to strict java deps setting
    if (ctx.fragments.java.strict_java_deps and
        ctx.fragments.java.strict_java_deps != "default"):
        return ctx.fragments.java.strict_java_deps
    return "error"

def _get_jdeps_config(
        ctx,

        # list[JavaInfo]
        deps = [],
        implicit_deps = [],

        # File
        output_jdeps = None,

        # off/error/warn
        strict_deps_mode = None,
        unused_deps_mode = None):
    return struct(
        strict_deps_mode = strict_deps_mode or _default_strict_deps(ctx),
        unused_deps_mode = unused_deps_mode or _default_unused_deps(ctx),
        direct_labels = [
            str(t.label)
            for t in getattr(ctx.attr, "deps", [])
        ],
        direct_jars = depset(transitive = [
            d.compile_jars
            for d in deps
        ] + [
            t[_AspectInfo].direct_jars_from_exports
            for t in getattr(ctx.attr, "deps", [])
        ]),
        aliased_labels = depset(transitive = [
            t[_AspectInfo].aliased_labels
            for t in getattr(ctx.attr, "deps", [])
        ]),
        classpath_jars = depset(transitive = [
            d.transitive_compile_time_jars
            for d in implicit_deps + deps
        ]),
        unused_deps_ignored_labels = [
            str(t.label)
            for t in getattr(ctx.attr, "unused_dependency_checker_ignored_targets", [])
        ],
        strict_deps_ignored_jars = depset(transitive = [
            # TODO: should we ignore all transitive from the toolchain, or just direct??
            d.transitive_compile_time_jars
            for d in implicit_deps
        ]),
    )

def _aspect_impl(target, ctx):
    # aliased_labels
    direct_aliased_labels = []
    exports_aliased_labels = []
    deps_aliased_labels = [
        t[_AspectInfo].aliased_labels
        for t in getattr(ctx.rule.attr, "deps", [])
        if _AspectInfo in t
    ]
    for t in getattr(ctx.rule.attr, "exports", []):
        if _AspectInfo in t:
            exports_aliased_labels += [t[_AspectInfo].aliased_labels]
        if JavaInfo in t:
            direct_aliased_labels += [str(t.label)]
    if ctx.rule.kind in [
        # needed to map the labels coming out of aspect-produced jars
        #  to the rule that puts them in the dependency graph.
        "scrooge_scala_library",
        "java_proto_library",
        "scalapb_proto_library",
    ]:
        for t in getattr(ctx.rule.attr, "deps", []):
            direct_aliased_labels += [str(t.label)]
    aliased_labels_order = "topological"
    aliased_labels = depset(
        order = aliased_labels_order,
        direct = [_LABEL_DELIMITER.join(
            [str(ctx.label)] + sorted(direct_aliased_labels),
        )] if direct_aliased_labels else [],
        transitive = exports_aliased_labels + [depset(
            # We put this in its own depset to maintain the topology
            #  (ie 'deps' are further away than 'exports')
            order = aliased_labels_order,
            transitive = deps_aliased_labels,
        )],
    )

    # direct_jars_from_exports
    transitive_direct_jars = []
    for t in getattr(ctx.rule.attr, "exports", []):
        if JavaInfo in t:
            transitive_direct_jars += [t[JavaInfo].compile_jars]
        if _AspectInfo in t:
            transitive_direct_jars += [t[_AspectInfo].direct_jars_from_exports]
    if ctx.toolchains["@io_bazel_rules_scala//scala:toolchain_type"].plus_one_deps_mode == "on":
        transitive_direct_jars += [
            t[JavaInfo].compile_jars
            for t
            in getattr(ctx.rule.attr, "deps", [])
            if JavaInfo in t
        ]
    direct_jars_from_exports = depset(transitive = transitive_direct_jars)

    info = _AspectInfo(
        direct_jars_from_exports = direct_jars_from_exports,
        aliased_labels = aliased_labels,
    )
    return [info]

jdeps_enforcer_aspect = aspect(
    _aspect_impl,
    attr_aspects = ["deps", "exports"],
    toolchains = ["@io_bazel_rules_scala//scala:toolchain_type"],
)

def has_jdeps_plugin(ctx):
    return hasattr(ctx.attr, "_scalac_jdeps_plugin")

def merge_jdeps_jars(
        ctx,
        # File
        output = None,
        output_jdeps = None,

        # list[File]
        jars = [],
        jdeps = [],

        # passed through to jdeps config
        **kwargs):
    cfg = _get_jdeps_config(ctx, **kwargs)
    args = ctx.actions.args()
    args.add("--output_jar", output)
    args.add("--output_jdeps", output_jdeps)
    for f in jars:
        args.add("--input_jar", f)
    for f in jdeps:
        args.add("--input_jdeps", f)
    args.add("--rule_label", str(ctx.label))
    args.add("--strict_deps_mode", cfg.strict_deps_mode)
    args.add("--unused_deps_mode", cfg.unused_deps_mode)
    args.add_all("--unused_deps_ignored_labels", cfg.unused_deps_ignored_labels)
    args.add_all("--strict_deps_ignored_jars", cfg.strict_deps_ignored_jars)
    args.add_all("--direct_jars", cfg.direct_jars)
    args.add_all("--direct_labels", cfg.direct_labels)
    args.add_all(cfg.aliased_labels, before_each = "--aliased_labels")
    tools, _, input_manifests = ctx.resolve_command(tools = [ctx.attr._jdeps_jar_merger])
    ctx.actions.run(
        inputs = depset(direct = jars + jdeps, transitive = [cfg.classpath_jars]),
        outputs = [output_jdeps, output],
        arguments = [args],
        executable = ctx.executable._jdeps_jar_merger,
        tools = tools,
        input_manifests = input_manifests,
    )

def add_scalac_jdeps_plugin_args(
        ctx,
        args,

        # File
        output_jdeps = None,

        # passed through to jdeps config
        **kwargs):
    """Returns depset[File] that needs to go into compilation action input"""

    jdeps_jars = ctx.attr._scalac_jdeps_plugin[JavaInfo].transitive_runtime_jars
    cfg = _get_jdeps_config(ctx, **kwargs)

    args.add("--scalac_opts", "-Xplugin-require:scala-jdeps")
    args.add_joined(
        "--scalac_opts",
        jdeps_jars,
        join_with = ctx.configuration.host_path_separator,
        format_joined = "-Xplugin:%s",
    )
    args.add("--scalac_opts", cfg.strict_deps_mode, format = "-P:scala-jdeps:dep_enforcer:strict_deps_mode:%s")
    args.add("--scalac_opts", cfg.unused_deps_mode, format = "-P:scala-jdeps:dep_enforcer:unused_deps_mode:%s")
    args.add("--scalac_opts", output_jdeps, format = "-P:scala-jdeps:output:%s")
    args.add("--scalac_opts", str(ctx.label), format = "-P:scala-jdeps:current-target:%s")
    args.add_joined(
        "--scalac_opts",
        cfg.classpath_jars,
        join_with = ctx.configuration.host_path_separator,
        format_joined = "-P:scala-jdeps:classpath-jars:%s",
    )
    args.add_joined(
        "--scalac_opts",
        cfg.unused_deps_ignored_labels,
        join_with = "::",
        format_joined = "-P:scala-jdeps:dep_enforcer:unused_deps_ignored_labels:%s",
    )
    args.add_joined(
        "--scalac_opts",
        cfg.strict_deps_ignored_jars,
        join_with = ctx.configuration.host_path_separator,
        format_joined = "-P:scala-jdeps:dep_enforcer:strict_deps_ignored_jars:%s",
    )

    args.add_joined(
        "--scalac_opts",
        cfg.direct_jars,
        join_with = ctx.configuration.host_path_separator,
        format_joined = "-P:scala-jdeps:dep_enforcer:direct_jars:%s",
    )

    args.add_joined(
        "--scalac_opts",
        cfg.direct_labels,
        join_with = "::",
        format_joined = "-P:scala-jdeps:dep_enforcer:direct_labels:%s",
    )

    args.add_all(
        cfg.aliased_labels,
        before_each = "--scalac_opts",
        format_each = "-P:scala-jdeps:dep_enforcer:aliased_labels:%s",
    )

    return jdeps_jars

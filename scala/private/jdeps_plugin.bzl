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

_EnforcerAspectInfo = provider(
    fields = {
        "labels": 'Map of origin/jar Label => "exported as Label"',
        "direct_jars_from_exports": "depset[File] of direct jars from exports",
    },
)

# Returns mapping between labels in 'deps' and labels which those deps export.
def _collect_deps_enforcer_info(ctx, rule_attr = None):
    rule_attr = rule_attr or ctx.attr
    labels = {}
    direct_labels = {}

    direct_jars_from_exports = []

    for t in getattr(rule_attr, "deps", []):
        if _EnforcerAspectInfo in t:
            labels.update(t[_EnforcerAspectInfo].labels)

    my_label = str(ctx.label)
    for t in getattr(rule_attr, "exports", []):
        direct_labels[str(t.label)] = my_label
        if _EnforcerAspectInfo in t:
            labels.update(t[_EnforcerAspectInfo].labels)

            direct_jars_from_exports += [t[_EnforcerAspectInfo].direct_jars_from_exports]
        if JavaInfo in t:
            direct_jars_from_exports += [t[JavaInfo].compile_jars]

    # needed to map the labels coming out of aspect produced jars to the rule that puts them
    # in the dependency graph.
    if ctx.rule.kind in [
        "scrooge_scala_library",
        "java_proto_library",
        "scalapb_proto_library",
    ]:
        for t in getattr(ctx.rule.attr, "deps", []):
            direct_labels[str(t.label)] = my_label

    # update 'exportedFrom' for anything that we're exporting
    for k, v in labels.items():
        if v in direct_labels:
            labels[k] = my_label
    labels.update(direct_labels)

    return _EnforcerAspectInfo(
        labels = labels,
        direct_jars_from_exports = depset(transitive = direct_jars_from_exports),
    )

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
    if not output_jdeps:
        fail("Must provide a File for output_jdeps")

    labels = {}

    direct_jars_from_exports = []
    for t in getattr(ctx.attr, "deps", []):
        labels.update(t[_EnforcerAspectInfo].labels)

        direct_jars_from_exports += [t[_EnforcerAspectInfo].direct_jars_from_exports]

    return struct(
        direct_labels = [
            str(t.label)
            for t in getattr(ctx.attr, "deps", [])
        ],
        direct_jars = depset(transitive = [
            d.compile_jars
            for d in deps
        ] + direct_jars_from_exports),
        classpath_jars = depset(transitive = [
            d.transitive_compile_time_jars
            for d in deps + implicit_deps
        ]),
        unused_deps_ignored_labels = [
            str(t.label)
            for t in getattr(ctx.attr, "unused_dependency_checker_ignored_targets", [])
        ],
        labels = labels,
        strict_deps_mode = strict_deps_mode or _default_strict_deps(ctx),
        unused_deps_mode = unused_deps_mode or _default_unused_deps(ctx),
        strict_deps_ignored_jars = depset(transitive = [
            # TODO: should we ignore all transitive from the toolchain, or just direct??
            d[JavaInfo].transitive_compile_time_jars
            for d in ctx.attr._scala_toolchain
        ]),
        output_jdeps = output_jdeps,
    )

def _impl(target, ctx):
    info = _collect_deps_enforcer_info(ctx, rule_attr = ctx.rule.attr)
    return [info]

jdeps_enforcer_aspect = aspect(
    _impl,
    attr_aspects = ["deps", "exports"],
)

def _default_unused_deps(ctx):
    # "--define unused_scala_deps=..." flag takes precedence
    if "unused_scala_deps" in ctx.var:
        return ctx.var["unused_scala_deps"]

    # otherwise use rule-configured setting (if present)
    if getattr(ctx.attr, "unused_dependency_checker_mode", None):
        return ctx.attr.unused_dependency_checker_mode

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
    return "off"

def has_jdeps_plugin(ctx):
    return hasattr(ctx.attr, "_scalac_jdeps_plugin")

def merge_jdeps_jars(
        ctx,
        # File
        output = None,

        # list[File]
        jars = [],
        jdeps = [],

        # passed through to jdeps config
        **kwargs):
    cfg = _get_jdeps_config(ctx, **kwargs)
    args = ctx.actions.args()
    args.add("--output_jar", output)
    args.add("--output_jdeps", cfg.output_jdeps)
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
    for actual, exported_from in cfg.labels.items():
        args.add_joined(
            "--deps_exported_labels",
            [actual, exported_from],
            join_with = "::",  # ':' is reserved & therefore won't collide
        )
    tools, _, input_manifests = ctx.resolve_command(tools = [ctx.attr._jdeps_jar_merger])
    ctx.actions.run(
        inputs = depset(direct = jars + jdeps, transitive = [cfg.classpath_jars]),
        outputs = [cfg.output_jdeps, output],
        arguments = [args],
        executable = ctx.executable._jdeps_jar_merger,
        tools = tools,
        input_manifests = input_manifests,
    )

def add_scalac_jdeps_plugin_args(
        ctx,
        args,

        # passed through to enforcer config
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
    args.add("--scalac_opts", cfg.output_jdeps, format = "-P:scala-jdeps:output:%s")
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

    # Make a mapping between labels in 'deps' and labels which those deps export.
    #  The dep enforcer needs this info.
    for actual, exported_from in cfg.labels.items():
        args.add_joined(
            "--scalac_opts",
            [actual, exported_from],
            join_with = "::",  # ':' is reserved & therefore won't collide
            format_joined = "-P:scala-jdeps:dep_enforcer:deps_exported_labels:%s",
        )

    return jdeps_jars

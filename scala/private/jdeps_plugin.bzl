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
        "unused_deps_ignored_jars": "depset[File] of transitive jars (eg from toolchains)",
        "direct_jars_from_exports": "depset[File] of direct jars from exports",
    },
)

# Returns mapping between labels in 'deps' and labels which those deps export.
def _collect_deps_enforcer_info(ctx, rule_attr = None):
    rule_attr = rule_attr or ctx.attr
    labels = {}
    direct_labels = {}
    unused_deps_ignored_jars = []
    direct_jars_from_exports = []

    for t in getattr(rule_attr, "_scala_toolchain", []):
        unused_deps_ignored_jars += [t[JavaInfo].transitive_compile_time_jars]

    for t in getattr(rule_attr, "deps", []):
        if _EnforcerAspectInfo in t:
            labels.update(t[_EnforcerAspectInfo].labels)
            unused_deps_ignored_jars += [t[_EnforcerAspectInfo].unused_deps_ignored_jars]

    my_label = str(ctx.label)
    for t in getattr(rule_attr, "exports", []):
        direct_labels[str(t.label)] = my_label
        if _EnforcerAspectInfo in t:
            labels.update(t[_EnforcerAspectInfo].labels)
            unused_deps_ignored_jars += [t[_EnforcerAspectInfo].unused_deps_ignored_jars]
            direct_jars_from_exports += [t[_EnforcerAspectInfo].direct_jars_from_exports]
        if JavaInfo in t:
            direct_jars_from_exports += [t[JavaInfo].compile_jars]

    # update 'exportedFrom' for anything that we're exporting
    for k, v in labels.items():
        if v in direct_labels:
            labels[k] = my_label
    labels.update(direct_labels)

    return _EnforcerAspectInfo(
        labels = labels,
        unused_deps_ignored_jars = depset(transitive = unused_deps_ignored_jars),
        direct_jars_from_exports = depset(transitive = direct_jars_from_exports),
    )

def _get_deps_enforcer_cfg(
        ctx,
        # list[depset[File]]
        direct_jars = None,
        # off/error/warn
        strict_deps_mode = None,
        unused_deps_mode = None):
    if direct_jars == None:
        fail("direct_jars cannot be 'None', wanted list[depset[File]]")
    labels = {}
    unused_deps_ignored_jars = []
    direct_jars_from_exports = []
    for t in getattr(ctx.attr, "deps", []):
        #        if _EnforcerAspectInfo in t:
        labels.update(t[_EnforcerAspectInfo].labels)
        unused_deps_ignored_jars += [t[_EnforcerAspectInfo].unused_deps_ignored_jars]
        direct_jars_from_exports += [t[_EnforcerAspectInfo].direct_jars_from_exports]

    return struct(
        direct_jars = depset(transitive = [direct_jars] + direct_jars_from_exports),
        unused_deps_ignored_jars = depset(transitive = [
            d[JavaInfo].compile_jars
            for d in getattr(ctx.attr, "unused_dependency_checker_ignored_targets", [])
        ] + unused_deps_ignored_jars),
        labels = labels,
        strict_deps_mode = strict_deps_mode or _default_strict_deps(ctx),
        unused_deps_mode = unused_deps_mode or _default_unused_deps(ctx),
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
        return ctx.var.unused_scala_deps

    # otherwise use rule-configured setting (if present)
    if getattr(ctx.attr, "unused_dependency_checker_mode", None):
        return ctx.attr.unused_dependency_checker_mode

    # fall back to toolchain default
    tc = ctx.toolchains["@io_bazel_rules_scala//scala:toolchain_type"]
    return tc.unused_dependency_checker_mode

def _default_strict_deps(ctx):
    # "--define strict_scala_deps=..." flag takes precedence
    if "strict_scala_deps" in ctx.var:
        return ctx.var.strict_scala_deps

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
        output_jdeps = None,

        # list[File]
        jars = [],
        jdeps = [],

        # passed through to enforcer config
        **kwargs):
    cfg = _get_deps_enforcer_cfg(ctx, **kwargs)
    args = ctx.actions.args()
    args.add("--output_jar", output)
    if output_jdeps:
        args.add("--output_jdeps", output_jdeps)
    for f in jars:
        args.add("--input_jar", f)
    for f in jdeps:
        args.add("--input_jdeps", f)
    args.add("--strict_deps_mode", cfg.strict_deps_mode)
    args.add("--unused_deps_mode", cfg.unused_deps_mode)
    args.add("--unused_deps_ignored_jars", cfg.unused_deps_ignored_jars)
    args.add("--direct_jars", cfg.direct_jars)
    for actual, exported_from in cfg.labels.items():
        args.add_joined(
            "--deps_exported_labels",
            [actual, exported_from],
            join_with = "::",  # ':' is reserved & therefore won't collide
        )
    tools, _, input_manifests = ctx.resolve_command(tools = [ctx.attr._jdeps_jar_merger])
    ctx.actions.run(
        inputs = jars + jdeps,
        outputs = [output] + (
            [output_jdeps] if output_jdeps else []
        ),
        arguments = [args],
        executable = ctx.executable._jdeps_jar_merger,
        tools = tools,
        input_manifests = input_manifests,
    )

def add_scalac_jdeps_plugin_args(
        ctx,
        args,
        # depset[File]
        classpath_jars = None,

        # File
        output_jdeps = None,

        # passed through to enforcer config
        **kwargs):
    """Returns depset[File] that needs to go into compilation action input"""
    if not output_jdeps:
        fail("Must provide a File for output_jdeps")
    jdeps_jars = ctx.attr._scalac_jdeps_plugin[JavaInfo].transitive_runtime_jars
    cfg = _get_deps_enforcer_cfg(ctx, **kwargs)

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
        classpath_jars,
        join_with = ctx.configuration.host_path_separator,
        format_joined = "-P:scala-jdeps:classpath-jars:%s",
    )
    args.add_joined(
        "--scalac_opts",
        cfg.unused_deps_ignored_jars,
        join_with = ctx.configuration.host_path_separator,
        format_joined = "-P:scala-jdeps:dep_enforcer:unused_deps_ignored_jars:%s",
    )
    args.add_joined(
        "--scalac_opts",
        cfg.direct_jars,
        join_with = ctx.configuration.host_path_separator,
        format_joined = "-P:scala-jdeps:dep_enforcer:direct_jars:%s",
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

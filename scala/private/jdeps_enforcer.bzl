DepsEnforcerInfo = provider(
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
        if DepsEnforcerInfo in t:
            labels.update(t[DepsEnforcerInfo].labels)
            unused_deps_ignored_jars += [t[DepsEnforcerInfo].unused_deps_ignored_jars]

    my_label = str(ctx.label)
    for t in getattr(rule_attr, "exports", []):
        direct_labels[str(t.label)] = my_label
        if DepsEnforcerInfo in t:
            labels.update(t[DepsEnforcerInfo].labels)
            unused_deps_ignored_jars += [t[DepsEnforcerInfo].unused_deps_ignored_jars]
            direct_jars_from_exports += [t[DepsEnforcerInfo].direct_jars_from_exports]
        if JavaInfo in t:
            direct_jars_from_exports += [t[JavaInfo].compile_jars]

    # update 'exportedFrom' for anything that we're exporting
    for k, v in labels.items():
        if v in direct_labels:
            labels[k] = my_label
    labels.update(direct_labels)

    return DepsEnforcerInfo(
        labels = labels,
        unused_deps_ignored_jars = depset(transitive = unused_deps_ignored_jars),
        direct_jars_from_exports = depset(transitive = direct_jars_from_exports),
    )

def _get_deps_enforcer_cfg(
        ctx,
        # list[depset[File]]
        direct_jars = [],
        # off/error/warn
        strict_deps_mode = None,
        unused_deps_mode = None):
    info = _collect_deps_enforcer_info(ctx)
    strict_deps_mode = strict_deps_mode or _default_strict_deps(ctx)
    unused_deps_mode = unused_deps_mode or _default_unused_deps(ctx)
    unused_deps_ignored_jars = depset(transitive = [
        d[JavaInfo].compile_jars
        for d in getattr(ctx.attr, "unused_dependency_checker_ignored_targets", [])
    ] + [info.unused_deps_ignored_jars])
    effective_direct_jars = depset(transitive = direct_jars + [info.direct_jars_from_exports])
    return struct(
        direct_jars = effective_direct_jars,
        unused_deps_ignored_jars = unused_deps_ignored_jars,
        labels = info.labels,
        strict_deps_mode = strict_deps_mode or _default_strict_deps(ctx),
        unused_deps_mode = unused_deps_mode or _default_unused_deps(ctx),
    )

def _impl(target, ctx):
    info = _collect_deps_enforcer_info(ctx, rule_attr = ctx.rule.attr)
    return [info]

deps_enforcer_aspect = aspect(
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

def add_enforcer_args_jdepsmerger(ctx, args, **kwargs):
    pass

def add_enforcer_args_scalacplugin(ctx, args, **kwargs):
    cfg = _get_deps_enforcer_cfg(ctx, **kwargs)
    args.add("--scalac_opts", strict_deps_mode, format = "-P:scala-jdeps:dep_enforcer:strict_deps_mode:%s")
    args.add("--scalac_opts", unused_deps_mode, format = "-P:scala-jdeps:dep_enforcer:unused_deps_mode:%s")
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
    for actual, exported_from in info.labels.items():
        args.add_joined(
            "--scalac_opts",
            [actual, exported_from],
            join_with = "::",  # ':' is reserved & therefore won't collide
            format_joined = "-P:scala-jdeps:dep_enforcer:deps_exported_labels:%s",
        )

ExportedLabels = provider(
    fields = {
        "labels": 'Map of origin/jar Label => "exported as Label"',
    },
)

# Returns mapping between labels in 'deps' and labels which those deps export.
def get_exported_labels(rule_attr, label):
    transitive = {}
    for attr in ["exports", "deps", "_scala_toolchain"]:
        for t in getattr(rule_attr, attr, []):
            if ExportedLabels in t:
                transitive.update(t[ExportedLabels].labels)
    my_label = str(label)
    direct = {
        str(e.label): my_label
        for e in getattr(rule_attr, "exports", []) + getattr(rule_attr, "_scala_toolchain", [])
    }
    # update 'exportedFrom' for anything that we're exporting
    for k, v in transitive.items():
        if v in direct:
            transitive[k] = my_label
    transitive.update(direct)
    return transitive


def _impl(target, ctx):
    return [ExportedLabels(
        labels = get_exported_labels(ctx.rule.attr, ctx.label),
    )]

exported_labels_aspect = aspect(
    _impl,
    attr_aspects = ["deps", "exports", "_scala_toolchain"],
)

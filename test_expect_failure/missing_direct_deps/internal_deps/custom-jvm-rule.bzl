def _custom_jvm_impl(ctx):
    print(ctx.label)
    transitive_compile_jars = _collect(ctx.attr.exports)
    return struct(
        providers = [
            java_common.create_provider(
                transitive_compile_time_jars = transitive_compile_jars,
            ),
        ],
    )

def _collect(deps):
    transitive_compile_jars = depset()
    for dep_target in deps:
        transitive_compile_jars += dep_target[JavaInfo].transitive_compile_time_jars
    return transitive_compile_jars

custom_jvm = rule(
    implementation = _custom_jvm_impl,
    attrs = {
        "exports": attr.label_list(),
    },
)

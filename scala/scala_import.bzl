load("@io_bazel_rules_scala//scala:jars_to_labels.bzl", "JarsToLabelsInfo")
load("//scala/private:pack_jar.bzl", "pack_jar")

_SOURCE_JAR_SUFFIXES = [
    "-src.jar",
    "-sources.jar",
]

#intellij part is tested manually, tread lightly when changing there
#if you change make sure to manually re-import an intellij project and see imports
#are resolved (not red) and clickable
def _scala_import_impl(ctx):
    output_files = []

    # separate jars from srcjars
    jar_files = {}
    srcjar_files = {}
    srcjar = getattr(ctx.file, "srcjar", None)
    for jar in ctx.files.jars or []:
        src = None
        for suffix in _SOURCE_JAR_SUFFIXES:
            if jar.path.endswith(suffix):
                srcjar_files[jar.path[:-len(suffix)]] = jar
                continue  # this was a srcjar, so move to next item
            else:
                # this wasn't a srcjar
                prefix = jar.path[:-len(".jar")]
                if prefix in jar_files:
                    # already processed this jar, so move to next
                    continue
                output_files += [jar]
                jar_files[prefix] = jar

    # create stuff from jars, pairing them with
    #   stamped compilejars (and srcjars if possible)
    jars = []
    for prefix, jar in jar_files.items():
        source_jar = srcjar_files.get(prefix, default = srcjar)
        compile_jar = java_common.stamp_jar(
            ctx.actions,
            jar = jar,
            target_label = ctx.label,
            java_toolchain = ctx.attr._java_toolchain,
        )
        jars += [struct(
            output_jar = jar,
            compile_jar = compile_jar,
            source_jar = source_jar,
        )]

    # create a "fake/empty" jar if none were provided (because the
    #   JavaInfo constructor requires one..)
    if not jars:
        # TODO: maybe deprecate nat providing jars??
        #print("scala_import: 'jars' is empty, it will be a required field in the future'")
        fakejar = ctx.actions.declare_file("lib%s.jar" % ctx.attr.name)
        pack_jar(ctx, output = fakejar)
        jars += [struct(output_jar = fakejar, compile_jar = fakejar, source_jar = None)]
        output_files += [fakejar]

    # grab any jar (doesn't matter which) just to make JavaInfo's constructor happy
    #  and use it to construct the returned provider
    anyjar = jars.pop()
    java_info = JavaInfo(
        output_jar = anyjar.output_jar,
        compile_jar = anyjar.compile_jar,
        source_jar = anyjar.source_jar,
        neverlink = ctx.attr.neverlink,
        deps = [d[JavaInfo] for d in getattr(ctx.attr, "deps", [])],
        runtime_deps = [d[JavaInfo] for d in getattr(ctx.attr, "runtime_deps", [])],
        exports = [d[JavaInfo] for d in getattr(ctx.attr, "exports", [])] + [
            JavaInfo(
                output_jar = j.output_jar,
                compile_jar = j.compile_jar,
                source_jar = j.source_jar,
            )
            for j in jars
        ],
    )
    return struct(
        scala = java_info,
        providers = [
            java_info,
            DefaultInfo(files = depset(direct = output_files)),
        ],
    )

scala_import = rule(
    implementation = _scala_import_impl,
    attrs = {
        "jars": attr.label_list(
            allow_files = True,
        ),  #current hidden assumption is that these point to full, not ijar'd jars
        "deps": attr.label_list(),
        "runtime_deps": attr.label_list(),
        "exports": attr.label_list(),
        "neverlink": attr.bool(),
        "srcjar": attr.label(allow_single_file = True),
        "_java_toolchain": attr.label(
            default = Label("@bazel_tools//tools/jdk:current_java_toolchain"),
        ),
        "_singlejar": attr.label(
            executable = True,
            cfg = "host",
            default = Label("@bazel_tools//tools/jdk:singlejar"),
            allow_files = True,
        ),
    },
)

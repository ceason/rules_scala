def _resource_dest_path(file, resource_strip_prefix):
    if resource_strip_prefix:
        if not file.short_path.startswith(resource_strip_prefix):
            fail("Resource file %s is not under the specified prefix to strip" % file.short_path)
        clean_path = file.short_path[len(resource_strip_prefix):]
        return clean_path

    #  Here we are looking to find out the offset of this resource inside
    #  any resources folder. We want to return the root to the resources folder
    #  and then the sub path inside it
    dir_1, dir_2, rel_path = file.short_path.partition("resources/")
    if rel_path:
        return rel_path

    #  The same as the above but just looking for java
    (dir_1, dir_2, rel_path) = file.short_path.partition("java")
    if rel_path:
        return rel_path

    return file.short_path

# Wrapper for @bazel_tools//src/tools/singlejar
# Use to combine resources & compiled sources
# flag docs @
#   https://github.com/bazelbuild/bazel/blob/ce714f8a1d93c540257d237144c88769251a0d62/src/tools/singlejar/options.cc#L36
def pack_jar(
        ctx,
        # File
        output = None,

        # bool
        compression = None,

        # string
        main_class = None,
        resource_strip_prefix = None,

        # list[File]
        resources = [],
        classpath_resources = [],
        jars = [],  # (resource jars *and* compilation output jars)

        # depset[File]
        transitive_jars = None):
    if not output:
        fail("Must provide 'output' kwarg")
    if not (resources or classpath_resources or jars or transitive_jars):
        fail("Must provide nonempty input to pack_jar")

    # set resource paths per:
    #  https://docs.bazel.build/versions/master/be/java.html#java_library
    inputs = []
    args = ctx.actions.args()
    args.add("--normalize")
    args.add("--exclude_build_data")
    args.add("--output", output)
    if compression == None:
        args.add("--dont_change_compression")
    elif compression:
        args.add("--compression")
    if main_class:
        args.add("--main_class", main_class)

    args.add_all("--classpath_resources", classpath_resources)
    input_jars = depset(
        direct = jars,
        transitive = [transitive_jars] if transitive_jars else [],
    )
    args.add_all("--sources", input_jars)
    args.add_all("--resources", [
        "%s:%s" % (f.path, _resource_dest_path(f, resource_strip_prefix))
        for f in resources
    ])

    ctx.actions.run(
        inputs = depset(
            direct = resources + classpath_resources,
            transitive = [input_jars],
        ),
        outputs = [output],
        executable = ctx.executable._singlejar,
        arguments = [args],
        mnemonic = "SingleJar",
        progress_message = "Packing jars to create %s" % output.path,
    )

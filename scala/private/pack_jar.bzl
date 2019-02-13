
# Wrapper for @bazel_tools//src/tools/singlejar
# Use to combine resources & compiled sources
# flag docs @
#   https://github.com/bazelbuild/bazel/blob/ce714f8a1d93c540257d237144c88769251a0d62/src/tools/singlejar/options.cc#L36
def pack_jar(
        ctx,
        # File
        output = None,

        # string
        main_class = None,
        resource_strip_prefix = "",

        # list[File]
        resources = [],
        classpath_resources = [],
        jars = [],  # (resource jars *and* compilation output jars)

        # depset[File]
        transitive_jars = None):
    # set resource paths per:
    #  https://docs.bazel.build/versions/master/be/java.html#java_library

    fail("Unimplemented.")
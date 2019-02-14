def _path_is_absolute(path):
    # Returns true for absolute path in Linux/Mac (i.e., '/') or Windows (i.e.,
    # 'X:\' or 'X:/' where 'X' is a letter), false otherwise.
    if len(path) >= 1 and path[0] == "/":
        return True
    if len(path) >= 3 and \
       path[0].isalpha() and \
       path[1] == ":" and \
       (path[2] == "/" or path[2] == "\\"):
        return True

    return False

def _runfiles_root(ctx):
    return "${TEST_SRCDIR}/%s" % ctx.workspace_name

def _format_classpath_jar(file):
    return "${RUNPATH}%s".replace('"', '\"') % file.short_path

def _shell_quote_str(s):
    return "'%s'" % s.replace("'", "\'")

def launcher(
        ctx,
        # File
        output = None,

        # depset[File],
        classpath_jars = None,

        # String
        wrapper_preamble = None,
        main_class = None,

        # list[String]
        extra_jvm_flags = []):
    if not main_class:
        fail("missing kwarg 'main_class'")

    # write wrapper
    wrapper_preamble = wrapper_preamble or "exec "
    java_path = str(ctx.attr._java_runtime[java_common.JavaRuntimeInfo].java_executable_runfiles_path)
    if _path_is_absolute(java_path):
        javabin = java_path
    else:
        runfiles_root = _runfiles_root(ctx)
        javabin = "%s/%s" % (runfiles_root, java_path)
    ctx.actions.write(
        output = wrapper,
        content = """#!/usr/bin/env bash
{wrapper_preamble}{javabin} "$@"
""".format(
            preamble = wrapper_preamble,
            javabin = javabin,
        ),
        is_executable = True,
    )

    # expand the java stub template
    template = ctx.attr._java_stub_template.files.to_list()[0]

    # args are <search> <replacement> pairs
    args = ctx.actions.args()
    args.add("%needs_runfiles%", "")
    args.add("%runfiles_manifest_only%", "")
    args.add("%set_jacoco_metadata%", "")
    args.add("%set_jacoco_main_class%", "")
    args.add("%set_jacoco_java_runfiles_root%", "")
    args.add("%workspace_prefix%", ctx.workspace_name + "/")
    args.add("%java_start_class%", main_class)
    args.add("%javabin%", "JAVABIN=%s/%s" % (
        _runfiles_root(ctx),
        wrapper.short_path,
    ))
    args.add_joined("%jvm_flags%", [
        ctx.expand_location(f, ctx.attr.data)
        for f in getattr(ctx.attr, "jvm_flags", []) + extra_jvm_flags
    ], join_with = " ", map_each = _shell_quote_str)
    args.add_joined(
        "%classpath%",
        classpath_jars,
        join_with = ":",
        map_each = _format_classpath_jar,
        format_joined = '"%s"',
    )
    ctx.actions.run_shell(
        inputs = [template],
        outputs = [output],
        env = {
            "TEMPLATE": template.path,
            "OUT": output.path,
        },
        command = """#!/usr/bin/env bash
        set -euo pipefail
        content="$(cat "$TEMPLATE")"
        while [[ $# -gt 0 ]]; do
            find="$1"; shift
            replacement="$1"; shift
            content="${content//"$find"/"$replacement"}"
        done
        echo -n "$content" > "$OUT"
        """,
    )

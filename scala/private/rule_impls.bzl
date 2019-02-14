# Copyright 2015 The Bazel Authors. All rights reserved.
#
# Licensed under the Apache License, Version 2.0 (the "License");
# you may not use this file except in compliance with the License.
# You may obtain a copy of the License at
#
#    http://www.apache.org/licenses/LICENSE-2.0
#
# Unless required by applicable law or agreed to in writing, software
# distributed under the License is distributed on an "AS IS" BASIS,
# WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
# See the License for the specific language governing permissions and
# limitations under the License.
"""Rules for supporting the Scala language."""

load(
    "@io_bazel_rules_scala//scala:providers.bzl",
    "create_scala_provider",
    _ScalacProvider = "ScalacProvider",
)
load(
    ":common.bzl",
    "add_labels_of_jars_to",
    "collect_jars",
    "collect_srcjars",
    "create_java_provider",
    "not_sources_jar",
    "write_manifest",
)
load("@io_bazel_rules_scala//scala:jars_to_labels.bzl", "JarsToLabelsInfo")
load(":impl_helper.bzl", "impl_helper")

_java_extension = ".java"
_scala_extension = ".scala"
_srcjar_extension = ".srcjar"

def _scalac_provider(ctx):
    return ctx.toolchains["@io_bazel_rules_scala//scala:toolchain_type"].scalac_provider_attr[_ScalacProvider]

def scala_library_impl(ctx):
    scalac_provider = _scalac_provider(ctx)
    return impl_helper(
        ctx,
        output_jar = ctx.outputs.jar,
        output_deploy_jar = ctx.outputs.deploy_jar,
        output_statsfile = ctx.outputs.statsfile,
        output_manifest = ctx.outputs.manifest,
        output_jdeps = ctx.actions.declare_file("%s.jdeps" % ctx.outputs.jar.basename[:-len(".jar")]),
        use_ijar = True,
    )

def scala_library_for_plugin_bootstrapping_impl(ctx):
    return impl_helper(
        ctx,
        output_jar = ctx.outputs.jar,
        output_deploy_jar = ctx.outputs.deploy_jar,
        output_statsfile = ctx.outputs.statsfile,
        output_manifest = ctx.outputs.manifest,
        output_jdeps = ctx.actions.declare_file("%s.jdeps" % ctx.outputs.jar.basename[:-len(".jar")]),
        use_ijar = False,
    )

def scala_macro_library_impl(ctx):
    scalac_provider = _scalac_provider(ctx)
    return impl_helper(
        ctx,
        output_jar = ctx.outputs.jar,
        output_deploy_jar = ctx.outputs.deploy_jar,
        output_statsfile = ctx.outputs.statsfile,
        output_manifest = ctx.outputs.manifest,
        output_jdeps = ctx.actions.declare_file("%s.jdeps" % ctx.outputs.jar.basename[:-len(".jar")]),
        use_ijar = False,
        extra_deps = [d[JavaInfo] for d in scalac_provider.default_macro_classpath],
    )

def scala_binary_impl(ctx):
    scalac_provider = _scalac_provider(ctx)
    return impl_helper(
        ctx,
        output_executable = ctx.outputs.executable,
        output_jar = ctx.outputs.jar,
        output_deploy_jar = ctx.outputs.deploy_jar,
        output_statsfile = ctx.outputs.statsfile,
        output_manifest = ctx.outputs.manifest,
        output_jdeps = ctx.actions.declare_file("%s.jdeps" % ctx.outputs.jar.basename[:-len(".jar")]),
    )

def scala_repl_impl(ctx):
    scalac_provider = _scalac_provider(ctx)
    return impl_helper(
        ctx,
        output_executable = ctx.outputs.executable,
        output_jar = ctx.outputs.jar,
        output_deploy_jar = ctx.outputs.deploy_jar,
        output_statsfile = ctx.outputs.statsfile,
        output_manifest = ctx.outputs.manifest,
        output_jdeps = ctx.actions.declare_file("%s.jdeps" % ctx.outputs.jar.basename[:-len(".jar")]),
        extra_deps = [d[JavaInfo] for d in scalac_provider.default_repl_classpath],
        extra_jvm_flags = ["-Dscala.usejavacp=true"],
        extra_args = ctx.attr.scalacopts or [],
        override_main_class = "scala.tools.nsc.MainGenericRunner",
        executable_wrapper_preamble = """
# save stty like in bin/scala
saved_stty=$(stty -g 2>/dev/null)
if [[ ! $? ]]; then
  saved_stty=""
fi
function finish() {
  if [[ "$saved_stty" != "" ]]; then
    stty $saved_stty
    saved_stty=""
  fi
}
trap finish EXIT
""",
    )

def scala_test_impl(ctx):
    if len(ctx.attr.suites) != 0:
        print("suites attribute is deprecated. All scalatest test suites are run")

    # output report test duration
    scalatest_flags = "-oD"
    if ctx.attr.full_stacktraces:
        scalatest_flags += "F"
    else:
        scalatest_flags += "S"
    if not ctx.attr.colors:
        scalatest_flags += "W"

    return impl_helper(
        ctx,
        output_executable = ctx.outputs.executable,
        output_jar = ctx.outputs.jar,
        output_deploy_jar = ctx.outputs.deploy_jar,
        output_statsfile = ctx.outputs.statsfile,
        output_manifest = ctx.outputs.manifest,
        output_jdeps = ctx.actions.declare_file("%s.jdeps" % ctx.outputs.jar.basename[:-len(".jar")]),
        deps_enforcer_ignored_jars = ctx.attr._scalatest[JavaInfo].compile_jars,
        extra_deps = [ctx.attr._scalatest[JavaInfo]],
        extra_runtime_deps = [
            ctx.attr._scalatest_reporter[JavaInfo],
            ctx.attr._scalatest_runner[JavaInfo],
        ],
        extra_args = [
            "-R",
            ctx.outputs.jar.short_path,
            scalatest_flags,
            "-C",
            "io.bazel.rules.scala.JUnitXmlReporter",
        ],
    )

def scala_junit_test_impl(ctx):
    if not (ctx.attr.prefixes or ctx.attr.suffixes):
        fail("Setting at least one of the attributes ('prefixes','suffixes') is required")

    test_archives = []
    if ctx.attr.tests_from:
        for t in ctx.attr.tests_from:
            test_archives += t[JavaInfo].runtime_output_jars
    else:
        test_archives += [ctx.outputs.jar]

    extra_deps = [
        ctx.attr._junit[JavaInfo],
        ctx.attr._hamcrest[JavaInfo],
        ctx.attr._bazel_test_runner[JavaInfo],
        ctx.attr.suite_label[JavaInfo],
    ]
    return impl_helper(
        ctx,
        output_executable = ctx.outputs.executable,
        output_jar = ctx.outputs.jar,
        output_deploy_jar = ctx.outputs.deploy_jar,
        output_statsfile = ctx.outputs.statsfile,
        output_manifest = ctx.outputs.manifest,
        output_jdeps = ctx.actions.declare_file("%s.jdeps" % ctx.outputs.jar.basename[:-len(".jar")]),
        override_main_class = "com.google.testing.junit.runner.BazelTestRunner",
        deps_enforcer_ignored_jars = depset(transitive = [j.compile_jars for f in extra_deps]),
        extra_deps = extra_deps,
        extra_jvm_flags = [
            "-ea",
            "-Dbazel.test_suite=%s" % ctx.attr.suite_class,
            "-Dbazel.discover.classes.archives.file.paths=%s" % ",".join([
                f.short_path
                for f in test_archives
            ]),
            "-Dbazel.discover.classes.prefixes=%s" % ",".join(ctx.attr.prefixes),
            "-Dbazel.discover.classes.suffixes=%s" % ",".join(ctx.attr.suffixes),
            "-Dbazel.discover.classes.print.discovered=%s" % ctx.attr.print_discovered_classes,
        ],
        extra_args = [
            "-R",
            ctx.outputs.jar.short_path,
            _scala_test_flags(ctx),
            "-C",
            "io.bazel.rules.scala.JUnitXmlReporter",
        ],
    )

# Produced by js_library().
JsLibraryInfo = provider(fields=[
  # Directory containing the JavaScript files (and potentially other assets).
  "full_src_dir",
  # Source files provided as input.
  "srcs",
  # Other js_library targets depended upon.
  "internal_deps",
  # Depset of npm_packages depended upon (at most one element).
  "npm_packages",
  # Directory in which node_modules/ with external NPM packages can be found.
  "npm_packages_installed_dir",
])

# Produced by npm_packages().
NpmPackagesInfo = provider(fields=[
  "installed_dir",
])

def _js_library_impl(ctx):
  # Ensure that we depend on at most one npm_packages, since we don't want to
  # have conflicting package versions coming from separate node_modules
  # directories.
  direct_npm_packages = [
    dep
    for dep in ctx.attr.deps
    if NpmPackagesInfo in dep
  ]
  if len(direct_npm_packages) > 1:
    fail("Found more than one set of NPM packages in target definition: " + ",".join([
      dep.label
      for dep in direct_npm_packages
    ]))
  if len(direct_npm_packages) == 0 and len(ctx.attr.requires) > 0:
    fail("js_library requires packages but does not depend on an npm_packages target.")
  extended_npm_packages = depset(
    direct = direct_npm_packages,
    transitive = [
      dep[JsLibraryInfo].npm_packages
      for dep in ctx.attr.deps
      if JsLibraryInfo in dep
    ],
  )
  npm_packages_list = extended_npm_packages.to_list()
  if len(npm_packages_list) > 1:
    fail("Found more than one set of NPM packages through dependencies: " + ",".join([
      dep.label
      for dep in npm_packages_list
    ]))
  # If we depend on an npm_packages target, we'll use its node_modules
  # directory to find modules. Otherwise, we'll use an empty node_modules
  # directory.
  npm_packages = (
    npm_packages_list[0] if len(npm_packages_list) == 1
    else ctx.attr._empty_npm_packages
  )
  # Gather all internal deps (other js_library rules).
  internal_deps = depset(
    direct = [
      dep
      for dep in ctx.attr.deps
      if JsLibraryInfo in dep
    ],
    transitive = [
      dep[JsLibraryInfo].internal_deps
      for dep in ctx.attr.deps
      if JsLibraryInfo in dep
    ],
  )
  # Create a directory that contains:
  # - source files
  # - node_modules (symlinked to installed external dependencies directory)
  # - __internal_node_modules/[name] for every internal dep
  _js_library_create_full_src(
    ctx,
    internal_deps,
    npm_packages,
  )
  _js_library_compile(
    ctx,
    npm_packages,
  )
  return [
    JsLibraryInfo(
      srcs = [f.path for f in ctx.files.srcs],
      full_src_dir = ctx.outputs.compiled_dir,
      internal_deps = internal_deps,
      npm_packages = extended_npm_packages,
      npm_packages_installed_dir = npm_packages[NpmPackagesInfo].installed_dir,
    ),
  ]

def _js_library_create_full_src(ctx, internal_deps, npm_packages):
  ctx.actions.run_shell(
    inputs = [
      ctx.attr._internal_packages[NpmPackagesInfo].installed_dir,
      ctx.file._js_library_create_full_src_script,
      npm_packages[NpmPackagesInfo].installed_dir,
    ] + [
      d[JsLibraryInfo].full_src_dir
      for d in internal_deps
    ] + ctx.files.srcs,
    outputs = [ctx.outputs.full_src_dir],
    command = "NODE_PATH=" + ctx.attr._internal_packages[NpmPackagesInfo].installed_dir.path + "/node_modules node \"$@\"",
    use_default_shell_env = True,
    arguments = [
      # Run `node process.js`.
      ctx.file._js_library_create_full_src_script.path,
      # Directory containing node_modules/ with all external NPM packages
      # installed.
      npm_packages[NpmPackagesInfo].installed_dir.path,
      # BUILD file path, necessary to understand relative "import" statements.
      ctx.build_file_path,
      # List of NPM package names used by the source files.
      ("|".join([
        p
        for p in ctx.attr.requires
      ])),
      # List of js_library targets we depend on, along with their source files
      # (required to replace relative "import" statements with the correct
      # module name).
      ("|".join([
        d.label.package + ':' +
        d.label.name + ':' +
        (";".join(d[JsLibraryInfo].srcs)) + ":" +
        d[JsLibraryInfo].full_src_dir.path
        for d in internal_deps
      ])),
      # List of source files, which will be processed ("import" statements
      # automatically replaced) and copied into the new directory.
      ("|".join([
        f.path for f in ctx.files.srcs
      ])),
      # Directory in which to place the result.
      ctx.outputs.full_src_dir.path,
    ],
  )

def _js_library_compile(ctx, npm_packages):
  ctx.actions.run_shell(
    inputs = [
      ctx.file._js_library_compile_script,
      ctx.outputs.full_src_dir,
      ctx.attr._internal_packages[NpmPackagesInfo].installed_dir,
      npm_packages[NpmPackagesInfo].installed_dir,
    ],
    outputs = [ctx.outputs.compiled_dir],
    command = "NODE_PATH=" + ctx.attr._internal_packages[NpmPackagesInfo].installed_dir.path + "/node_modules node \"$@\"",
    use_default_shell_env = True,
    arguments = [
      # Run `node js_library/compile.js`.
      ctx.file._js_library_compile_script.path,
      # Directory in which the source code can be found.
      ctx.outputs.full_src_dir.path,
      # Directory in which to output the compiled JavaScript.
      ctx.outputs.compiled_dir.path,
    ],
  )

js_library = rule(
  implementation=_js_library_impl,
  attrs = {
    "srcs": attr.label_list(
      allow_files = True,
    ),
    "deps": attr.label_list(
      providers = [
        [JsLibraryInfo],
        [NpmPackagesInfo],
      ],
      default = [],
    ),
    "requires": attr.string_list(
      default = [],
    ),
    "_internal_packages": attr.label(
      default = Label("//internal:packages"),
    ),
    "_js_library_create_full_src_script": attr.label(
      allow_files = True,
      single_file = True,
      default = Label("//internal/js_library:create_full_src.js"),
    ),
    "_js_library_compile_script": attr.label(
      allow_files = True,
      single_file = True,
      default = Label("//internal/js_library:compile.js"),
    ),
    "_empty_npm_packages": attr.label(
      default = Label("@bazel_node//internal/npm_packages/empty:packages"),
    ),
  },
  outputs = {
    "compiled_dir": "%{name}_compiled",
    "full_src_dir": "%{name}_full_src",
  },
)

def _js_script_impl(ctx):
  # Create a directory that contains:
  # - source code from the js_library we depend on
  # - package.json with {
  #     "scripts": {
  #       "start": "[cmd]"
  #     }
  #   }
  #
  # Note that node_modules/ will not contain external dependencies from NPM.
  # Instead, the NODE_PATH will point to the node_modules/ directory of
  # the npm_packages target we depend on. This means we don't have to lose
  # performance by copy-pasting node_modules with hundreds of packages.
  #
  # Also generate a shell script that will run `yarn start`.
  ctx.actions.run_shell(
    inputs = [
      ctx.attr._internal_packages[NpmPackagesInfo].installed_dir,
      ctx.attr.lib[JsLibraryInfo].npm_packages_installed_dir,
      ctx.attr.lib[JsLibraryInfo].full_src_dir,
      ctx.file._js_script_compile_script,
    ],
    outputs = [
      ctx.outputs.compiled_dir,
      ctx.outputs.executable_file,
    ],
    command = "NODE_PATH=" + ctx.attr._internal_packages[NpmPackagesInfo].installed_dir.path + "/node_modules node \"$@\"",
    use_default_shell_env = True,
    arguments = [
      # Run `node js_script/compile.js`.
      ctx.file._js_script_compile_script.path,
      # The command to run.
      ctx.attr.cmd,
      # Directory containing node_modules/ with all external NPM packages
      # installed.
      ctx.attr.lib[JsLibraryInfo].npm_packages_installed_dir.path,
      # Same path required in short form for the shell script.
      ctx.attr.lib[JsLibraryInfo].npm_packages_installed_dir.short_path,
      # Compiled directory of the js_library we depend on.
      ctx.attr.lib[JsLibraryInfo].full_src_dir.path,
      # Directory in which to create package.json and copy sources.
      ctx.outputs.compiled_dir.path,
      # Same path required in short form for the shell script.
      ctx.outputs.compiled_dir.short_path,
      # Path to generate the shell script.
      ctx.outputs.executable_file.path,
    ],
  )
  return [
    DefaultInfo(
      executable = ctx.outputs.executable_file,
      runfiles = ctx.runfiles(
        files = [
          ctx.attr.lib[JsLibraryInfo].npm_packages_installed_dir,
          ctx.outputs.compiled_dir,
        ],
      ),
    ),
  ]

js_script = rule(
  implementation = _js_script_impl,
  attrs = {
    "cmd": attr.string(),
    "lib": attr.label(
      providers = [JsLibraryInfo],
    ),
    "_internal_packages": attr.label(
      default = Label("//internal:packages"),
    ),
    "_js_script_compile_script": attr.label(
      allow_files = True,
      single_file = True,
      default = Label("//internal/js_script:compile.js"),
    ),
  },
  executable = True,
  outputs = {
    "compiled_dir": "%{name}_compiled_dir",
    "executable_file": "%{name}.sh",
  },
)

# js_test is identical to js_script, but it's marked as "test" instead of
# "executable".
js_test = rule(
  implementation = _js_script_impl,
  attrs = {
    "cmd": attr.string(),
    "lib": attr.label(
      providers = [JsLibraryInfo],
    ),
    "_internal_packages": attr.label(
      default = Label("//internal:packages"),
    ),
    "_js_script_compile_script": attr.label(
      allow_files = True,
      single_file = True,
      default = Label("//internal/js_script:compile.js"),
    ),
  },
  test = True,
  outputs = {
    "compiled_dir": "%{name}_compiled_dir",
    "executable_file": "%{name}.sh",
  },
)

def _js_binary_impl(ctx):
  ctx.actions.run_shell(
    inputs = [
      ctx.attr._internal_packages[NpmPackagesInfo].installed_dir,
      ctx.attr.lib[JsLibraryInfo].npm_packages_installed_dir,
      ctx.attr.lib[JsLibraryInfo].full_src_dir,
    ] + ctx.files._js_binary_compile_script,
    outputs = [
      ctx.outputs.executable_file,
    ],
    command = "NODE_PATH=" + ctx.attr._internal_packages[NpmPackagesInfo].installed_dir.path + "/node_modules node \"$@\"",
    use_default_shell_env = True,
    arguments = [
      # Run `node js_binary/compile.js`.
      ctx.file._js_binary_compile_script.path,
      # Entry point for Webpack (e.g. "main.ts").
      ctx.attr.entry,
      # Directory containing external NPM dependencies the code depends on.
      ctx.attr.lib[JsLibraryInfo].npm_packages_installed_dir.path,
      # Directory containing the compiled source code of the js_library.
      ctx.attr.lib[JsLibraryInfo].full_src_dir.path,
      # Directory in which to place the compiled JavaScript.
      ctx.outputs.executable_file.path,
    ],
  )
  return [
    DefaultInfo(
      executable = ctx.outputs.executable_file,
    ),
  ]

js_binary = rule(
  implementation=_js_binary_impl,
  attrs = {
    "lib": attr.label(
      providers = [JsLibraryInfo],
    ),
    "entry": attr.string(),
    "_internal_packages": attr.label(
      default = Label("//internal:packages"),
    ),
    "_js_binary_compile_script": attr.label(
      allow_files = True,
      single_file = True,
      default = Label("//internal/js_binary:compile.js"),
    ),
  },
  executable = True,
  outputs = {
    "executable_file": "%{name}.js",
  },
)

def _npm_packages_impl(ctx):
  ctx.actions.run_shell(
    inputs = [
      ctx.file._npm_packages_install,
      ctx.file.package_json,
      ctx.file.yarn_lock,
    ],
    outputs = [ctx.outputs.installed_dir],
    command = "node \"$@\"",
    use_default_shell_env = True,
    arguments = [
      # Run `node npm_packages/install.js`.
      ctx.file._npm_packages_install.path,
      # Path of package.json to install with.
      ctx.file.package_json.path,
      # Path of yarn.lock to lock versions.
      ctx.file.yarn_lock.path,
      # Path to install into (node_modules/ will be created there).
      ctx.outputs.installed_dir.path,
    ],
  )
  return [
    NpmPackagesInfo(
      installed_dir = ctx.outputs.installed_dir
    ),
  ]

npm_packages = rule(
  implementation = _npm_packages_impl,
  attrs = {
    "package_json": attr.label(
      allow_files = True,
      single_file = True,
    ),
    "yarn_lock": attr.label(
      allow_files = True,
      single_file = True,
    ),
    "_npm_packages_install": attr.label(
      allow_files = True,
      single_file = True,
      default = Label("//internal/npm_packages:install.js"),
    ),
  },
  outputs = {
    "installed_dir": "%{name}_installed_dir",
  },
)

def _npm_binary_impl(ctx):
  # Generate a simple shell script that starts the binary, loaded from the
  # node_modules/.bin directory.
  ctx.actions.write(
    output = ctx.outputs.bin,
    content = "%s/node_modules/.bin/%s" % (
      ctx.attr.install[NpmPackagesInfo].installed_dir.short_path,
      ctx.attr.binary,
    ),
    is_executable = True,
  )
  return [
    DefaultInfo(
      runfiles = ctx.runfiles(
        files = [
          ctx.attr.install[NpmPackagesInfo].installed_dir,
        ],
      ),
      executable = ctx.outputs.bin,
    )
  ]

npm_binary = rule(
  implementation = _npm_binary_impl,
  attrs = {
    "install": attr.label(
      providers = [NpmPackagesInfo],
    ),
    "binary": attr.string(),
  },
  outputs = {
    "bin": "%{name}.sh"
  },
  executable = True,
)

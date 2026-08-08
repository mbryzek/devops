# Resolving a node CLI that a build step shells out to, repo-local first.
#
# The version of a build tool is a property of the repo being built, and the only
# place that property can live is that repo's package.json. A global install is
# shared by every app on the machine, so it can only ever match one app's pins at
# a time — and on a machine that never had it (an agent runner, a new laptop, a CI
# box) there is nothing on PATH at all and the build refuses to run. Neither
# failure is loud where it happens: `elm` was the wrong compiler for one of the
# two elm apps whichever one you picked (ISS-1068), and `uglifyjs` was declared in
# acumen-ui's package.json as a stub package that ships no bin, so the release was
# always minifying with whatever global happened to be installed — which worked on
# exactly one machine and refused everywhere else (ISS-1074).
#
# So: prefer <repo>/node_modules/.bin/<cmd>, which npm installs at the version the
# repo pinned, and fall back to a global only when the repo has not declared one.
# Same rationale as review.sh running elm-review out of node_modules.
module NodeBin
  module_function

  # An absolute path to the repo-local binary when one is installed, else the bare
  # command name when a global exists. Exits with an actionable error when neither
  # does — naming BOTH remedies, because "Please install uglifyjs" sends you to a
  # global install, which is the thing this module exists to stop being the answer.
  #
  # `dir` is the repo root; every caller is a release script, which runs from it.
  # `package` is the npm package name when it differs from the command (uglify-js
  # ships `uglifyjs`) — getting that wrong is how the stub package was declared.
  def resolve(cmd, package: nil, url: nil, dir: Dir.pwd)
    local = local_path(cmd, dir: dir)
    return local if File.executable?(local)
    return cmd if global?(cmd)

    Util.exit_with_error(missing_message(cmd, package: package, url: url, dir: dir))
  end

  def local_path(cmd, dir: Dir.pwd)
    File.join(dir, "node_modules", ".bin", cmd)
  end

  # Which of `cmds` the repo has not installed. A caller with something to
  # install runs `npm install` and resolves again; one with nothing to install
  # skips it entirely, which is the common case and the fast one.
  #
  # This is what keeps a pin from being decorative. node_modules is not part of
  # the checkout, so it is routinely BEHIND package.json — most obviously the
  # first time any machine releases after a tool is newly declared, when the
  # installed tree is yesterday's and nothing has re-installed. In that state
  # `resolve` falls through to a global, silently, which is the exact
  # machine-to-machine variation the pin exists to remove. review.sh already
  # guards elm-review this way; this is the same guard for the tools the release
  # itself shells out to.
  def missing(cmds, dir: Dir.pwd)
    cmds.reject { |c| File.executable?(local_path(c, dir: dir)) }
  end

  def global?(cmd)
    system("which #{cmd} > /dev/null 2>&1")
  end

  # Kept separate from `resolve` so the message can be asserted on without a test
  # having to arrange for a command that exists nowhere on the box.
  def missing_message(cmd, package: nil, url: nil, dir: Dir.pwd)
    pkg = package || cmd
    suffix = url ? " (#{url})" : ""
    [
      "#{cmd} not found.",
      "  Add \"#{pkg}\" to devDependencies in #{File.join(dir, "package.json")} and run `npm install`#{suffix},",
      "  or install #{pkg} globally.",
    ].join("\n")
  end
end

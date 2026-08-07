#!/usr/bin/env ruby
require 'minitest/autorun'

# bin/ is PREPENDED to PATH — lib/agent/toolchain.rb hands out
# `export PATH="$HOME/code/devops/bin:$PATH"` as the install instruction for its
# own tools — so every name in here wins over the system command of the same
# name, for every shell on the machine, forever.
#
# That is not a style problem. bin/env used to sit here, and it prints every
# resolved secret for an app to stdout with no flag asked for. So the most
# ordinary line in POSIX shell,
#
#   env CONF_DB_DEV_URL=... SBT_OPTS=-Xmx12G sbt 'core/testOnly ...'
#
# ran this repo's dumper instead of /usr/bin/env and wrote the prod DB URL with
# its password, SendGrid, Stripe, Twilio, DO Spaces, NewRelic, the Claude keys
# and the Play crypto secret into a log file, on one line, having been asked to
# set two variables (ISS-893, 2026-08-07). Nothing in that command reads as
# "print secrets", which is exactly why the standing "never run bare `env`" rule
# did not save it: the author was not running bare `env`.
#
# The rename fixed that one name. This fixes the CLASS: any future collision
# fails the suite here, at the moment the file is added, rather than in somebody's
# log months later.
class TestBinShadowsNoSystemCommand < Minitest::Test
  ROOT = File.expand_path("..", __dir__)

  # A fixed list on purpose. It is the POSIX system-command set that exists
  # identically on every runner and laptop the fleet uses, so this test's verdict
  # comes from the repo's own contents and never from ambient machine state —
  # the confound that made an earlier guard read green on laptops and red on the
  # runners (ISS-613). Homebrew is deliberately NOT scanned: /opt/homebrew/bin
  # comes BEFORE this directory on PATH, so a name shared with it is shadowed the
  # other way (our tool loses), which is loud rather than dangerous.
  SYSTEM_DIRS = %w[/usr/bin /bin /usr/sbin /sbin].freeze

  def test_no_bin_script_shadows_a_system_command
    collisions = Dir.children(File.join(ROOT, "bin")).sort.flat_map { |name|
      SYSTEM_DIRS
        .map { |dir| File.join(dir, name) }
        .select { |path| File.executable?(path) && !File.directory?(path) }
        .map { |path| "  bin/#{name} shadows #{path}" }
    }

    assert_empty collisions, <<~MSG
      A script in bin/ has the same name as a system command:

      #{collisions.join("\n")}

      bin/ is prepended to PATH, so this name now wins everywhere on the machine
      and anyone typing the system command silently gets ours instead. Rename it
      to something hyphenated that cannot collide (bin/env became bin/app-env for
      exactly this reason — see ISS-893), and update its callers.
    MSG
  end

  # The specific name, pinned by itself, because it is the one whose return would
  # leak secrets rather than merely confuse. A future `bin/env` would also trip
  # the test above; this one names the consequence, so whoever hits it reads why
  # instead of just how.
  def test_bin_env_is_never_reintroduced
    refute_path_exists File.join(ROOT, "bin", "env"),
                       "bin/env shadows /usr/bin/env for every shell on the machine, and it " \
                       "prints every app secret to stdout. `env VAR=x cmd` — two variables and " \
                       "a command — dumped the whole production secret set into a log (ISS-893). " \
                       "The tool is bin/app-env; do not restore this name, not even as a shim."
  end
end

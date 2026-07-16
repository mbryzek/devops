# Guard against releasing a stale checkout: a local main behind origin/main
# silently ships old code (michaelbryzek 0.0.66, 2026-07-16 — released without
# the just-merged version-endpoint fix). Recover with a fast-forward pull and
# only stop the release when recovery isn't cleanly possible.
module ReleaseFreshness
  def self.ensure!(dir = Dir.pwd)
    branch = `git -C #{dir} rev-parse --abbrev-ref HEAD`.strip
    unless %w[main master].include?(branch)
      Util.exit_with_error("Refusing to release from branch '#{branch}' — release from main")
    end

    fetch_out = `git -C #{dir} fetch origin 2>&1`
    unless $?.success?
      Util.exit_with_error("git fetch failed — cannot verify the checkout is current:\n#{fetch_out.strip}")
    end

    behind = `git -C #{dir} rev-list --count HEAD..origin/#{branch}`.strip.to_i
    return if behind.zero?

    puts "Local #{branch} is #{behind} commit(s) behind origin/#{branch}; pulling (--ff-only)..."
    pull_out = `git -C #{dir} pull --ff-only origin #{branch} 2>&1`
    unless $?.success?
      Util.exit_with_error("Checkout is stale and could not fast-forward (diverged or dirty tree?):\n#{pull_out.strip}")
    end
  end
end

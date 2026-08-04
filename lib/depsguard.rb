require 'open3'

# `dev depsguard` — run `depsguard scan` and suppress one known false positive.
#
# Every app repo here is npm-only (package-lock.json, no pnpm-lock.yaml) and is
# deliberately kept that way, so pnpm's `minimum-release-age` key is meaningless
# noise in their `.npmrc`. depsguard flags it anyway, and the weekly auto-fixer
# kept re-adding the key to apibuilder-ui — endless add/revert churn on main.
# Dropping that specific failure BEFORE anything downstream sees it is what stops
# the key from ever being added.
#
# Ported from `openclaw-workspace/scripts/depsguard-wrapped`, which the
# `depsguard-weekly` cron ran. It already had the producer's exit contract
# (0 = clean, 1 = real failures on stdout); the port is what lets the check live
# in a tested repo instead of an untracked script beside a cron prompt.
module Depsguard
  SCAN_CMD = %w[depsguard scan --no-color].freeze

  Result = Struct.new(:exit_code, :lines, keyword_init: true)

  module_function

  # Runs the scan and returns a Result whose exit_code is the producer contract:
  #   0  no real failures
  #   1  real failures, listed in `lines`
  #   2  the scan itself could not run — NOT evidence of a config problem
  def run(capture: method(:capture_scan), fs: File)
    stdout, stderr, status = capture.call
    return Result.new(exit_code: 2, lines: ["depsguard: 'depsguard' not found in PATH"]) if status.nil?

    if !status.success? && stdout.strip.empty?
      return Result.new(exit_code: 2, lines: ["depsguard: scan command failed (exit #{status.exitstatus})", *strip_ansi(stderr).lines.map(&:chomp)])
    end

    real, suppressed = classify(strip_ansi(stdout), fs: fs)
    lines = suppressed.map { |cfg, chk| "suppressed (npm-only pnpm false positive) #{chk}  [#{cfg}]" }

    if real.empty?
      # depsguard 0.1.33 always exits 0. If a future version signals trouble via
      # a nonzero exit, surface it rather than reporting a false all-clear.
      unless status.success?
        return Result.new(exit_code: 2, lines: ["depsguard: no failures parsed but depsguard exited #{status.exitstatus}", *strip_ansi(stderr).lines.map(&:chomp)])
      end
      return Result.new(exit_code: 0, lines: [*lines, "All depsguard checks pass (npm-only pnpm false positives suppressed)."])
    end

    Result.new(exit_code: 1, lines: [
      *lines,
      "depsguard: #{real.length} real failure(s) need attention:",
      *real.map { |cfg, chk| "  #{chk}#{cfg ? "  [#{cfg}]" : ''}" },
    ])
  end

  def capture_scan
    Open3.capture3(*SCAN_CMD)
  rescue Errno::ENOENT
    [nil, nil, nil]
  end

  # Splits scan output into [real_failures, suppressed], each an array of
  # [config_path, check_line].
  def classify(output, fs: File)
    current_config = nil
    real = []
    suppressed = []
    output.each_line do |raw|
      line = raw.rstrip
      if (m = line.match(/^\s*Config:\s*(\S+)/))
        current_config = expand(m[1])
        next
      end
      next unless line.include?("✗") # ✗
      check = line.strip
      if current_config && npm_only_npmrc?(current_config, fs: fs) && pnpm_release_age_failure?(check)
        suppressed << [current_config, check]
      else
        real << [current_config, check]
      end
    end
    [real, suppressed]
  end

  # A repo `.npmrc` owned by a repo that uses npm and not pnpm. The global
  # ~/.npmrc is never treated as npm-only: it governs every npm invocation
  # system-wide, so its failures must always surface (and $HOME happens to hold
  # a stray package-lock.json on this machine).
  def npm_only_npmrc?(config_path, fs: File)
    return false unless config_path.end_with?("/.npmrc")
    dir = File.dirname(config_path)
    return false if dir == Dir.home
    fs.exist?(File.join(dir, "package-lock.json")) && !fs.exist?(File.join(dir, "pnpm-lock.yaml"))
  end

  def pnpm_release_age_failure?(check_line) = check_line.match?(/\(pnpm\)\s*minimum-release-age/)

  def strip_ansi(str)
    str.to_s.encode("UTF-8", invalid: :replace, undef: :replace, replace: "").gsub(/\e\[[0-9;]*m/, "")
  end

  def expand(path) = path.start_with?("~") ? path.sub(/\A~/, Dir.home) : path
end

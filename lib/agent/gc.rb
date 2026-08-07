require 'fileutils'
require 'set'
require 'time'
require 'agent/jobs'
require 'agent/paths'
require 'agent/workspace'

# Retention (design §4.3.1). One rule per kind, applied by `dev agent gc` and by
# the tick's runner-local maintenance pass (Agent::Maintenance) — every machine
# collects its own logs and workspaces, because these are files on THIS disk and
# nothing another machine does frees them (ISS-520).
#
#   tick/, producers/                       30 days
#   issues/<n>/ for a terminal issue        14 days after completion
#   issues/<n>/ for a failed / gave-up one  30 days — the post-mortem window
#   ~/code/ai/<slug>/ workspaces            deleted on success; 7 days otherwise
#
# Failure gets the longer window on purpose: a successful run's log is rarely
# read again, and a failure is exactly what someone comes looking for a week
# later.
#
# `plan` is pure w.r.t. the decision (it only stats the filesystem) and `apply`
# does the deleting, so --dry-run prints precisely what a real run would remove.
module Agent
  module Gc
    ROTATED_LOG_DAYS = 30
    TERMINAL_ISSUE_DAYS = 14
    FAILED_ISSUE_DAYS = 30
    WORKSPACE_DAYS = 7

    # What `workspace_days` drops to when the machine is under disk pressure
    # (Agent::Maintenance). Only the WORKSPACE window shortens: a feature dir is
    # several full clones plus node_modules and is exactly what fills a disk,
    # while the log windows above hold a few MB and are the post-mortem record.
    # Trading the record for megabytes would be a bad bargain in the one moment
    # someone is most likely to need it.
    #
    # One day is still far outside a live job's reach: the hard timeout is 4
    # hours (Agent::Jobs::TIMEOUT_SECONDS), and `workspaces` refuses to collect a
    # slug with a live pid regardless.
    PRESSURE_WORKSPACE_DAYS = 1

    # Outcomes that end an issue's work. Anything else (a failure, a give-up)
    # keeps the longer post-mortem window.
    TERMINAL_OUTCOMES = %w[ready_pr design_document operation_completed nothing_to_do].freeze

    # Only directories the executor itself created, ever. `~/code/ai` is also
    # where Mike's own feature dirs live and this runs unattended with rm -rf.
    #
    # Taken from Agent::Workspace rather than restated: the pattern has to mean
    # "what Workspace.slug produces", and two copies of that could drift apart
    # into a gc that either misses real workspaces or matches a hand-made
    # feature dir.
    AGENT_SLUG = Agent::Workspace::SLUG

    module_function

    def retention_days(meta)
      outcome = meta && meta["outcome"] && meta["outcome"]["name"]
      return FAILED_ISSUE_DAYS if outcome && !TERMINAL_OUTCOMES.include?(outcome)
      TERMINAL_ISSUE_DAYS
    end

    def age_days(time, now) = (now - time) / 86_400.0

    # [[path, reason], ...] — everything a run would delete right now.
    def plan(now: Time.now, workspace_days: WORKSPACE_DAYS)
      rotated_logs(now) + issue_dirs(now) + workspaces(now, workspace_days)
    end

    # `producers/` is swept but never written anymore: producers moved into the
    # platform entirely (ISS-526), so what is left on a machine is history. Kept
    # in the sweep precisely because nothing writes it — dropping it would leave
    # up to 30 days of files on every runner with nothing that ever collects them.
    def rotated_logs(now)
      %w[tick producers].flat_map do |kind|
        dir = File.join(Agent::Paths.log_root, kind)
        next [] unless Dir.exist?(dir)
        Dir.glob(File.join(dir, "*.log")).sort.filter_map do |f|
          date = File.basename(f, ".log")
          at = (Time.parse("#{date} 00:00:00") rescue nil)
          next if at.nil?
          next unless age_days(at, now) > ROTATED_LOG_DAYS
          [f, "#{kind} log older than #{ROTATED_LOG_DAYS} days"]
        end
      end
    end

    # An issue directory with no finished_at is a job still running (or one whose
    # tick died mid-reap). Never collected — the cost of keeping it is a few KB,
    # and deleting a live session's log is unrecoverable.
    def issue_dirs(now)
      dir = Agent::Paths.issues_dir
      return [] unless Dir.exist?(dir)
      Dir.children(dir).sort.filter_map do |name|
        path = File.join(dir, name)
        meta = Agent::Paths.read_json(File.join(path, "meta.json"))
        finished = meta && meta["finished_at"] && (Time.parse(meta["finished_at"]) rescue nil)
        next if finished.nil?
        days = retention_days(meta)
        next unless age_days(finished, now) > days
        [path, "#{name} finished #{age_days(finished, now).round} days ago (keep #{days})"]
      end
    end

    # Slugs a LIVE session is working in. mtime alone is not enough to answer
    # "is anyone using this": a job clones its repos in the first minute and then
    # works inside them for hours, so the feature dir's own mtime stops moving
    # while the session is still very much running. At the 7-day default that
    # gap is unreachable, but `workspace_days` shortens under disk pressure and
    # "we were low on disk" is the worst possible reason to delete a running
    # session's working tree out from under it.
    def live_slugs
      Agent::Jobs.all.select { |r| Agent::Jobs.alive?(r["pid"]) }.map { |r| r["slug"] }.compact.to_set
    end

    def workspaces(now, days = WORKSPACE_DAYS)
      root = Agent::Paths.workspace_root
      return [] unless Dir.exist?(root)
      live = live_slugs
      Dir.children(root).sort.filter_map do |name|
        next unless name.match?(AGENT_SLUG)
        next if live.include?(name)
        path = File.join(root, name)
        next unless File.directory?(path)
        next unless age_days(File.mtime(path), now) > days
        [path, "agent workspace idle #{age_days(File.mtime(path), now).round} days (keep #{days})"]
      end
    end

    def apply(entries)
      entries.each { |path, _reason| FileUtils.rm_rf(path) }
      entries.length
    end
  end
end

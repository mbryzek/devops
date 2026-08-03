require 'fileutils'
require 'time'
require 'agent/paths'
require 'agent/workspace'

# Retention (design §4.3.1). One rule per kind, applied by `dev agent gc`, which
# runs as a producer at 4:00am through the same registry as everything else —
# retention is a producer, not a cron, so it inherits the run history and mutual
# exclusion the rest of the system has.
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

    # Outcomes that end an issue's work. Anything else (a failure, a give-up)
    # keeps the longer post-mortem window.
    TERMINAL_OUTCOMES = %w[ready_pr design_document nothing_to_do].freeze

    # Only directories the executor itself created, ever. `~/code/ai` is also
    # where Mike's own feature dirs live and this runs unattended with rm -rf.
    AGENT_SLUG = /\Ai\d+_[a-z0-9]{3}\z/

    module_function

    def retention_days(meta)
      outcome = meta && meta["outcome"] && meta["outcome"]["name"]
      return FAILED_ISSUE_DAYS if outcome && !TERMINAL_OUTCOMES.include?(outcome)
      TERMINAL_ISSUE_DAYS
    end

    def age_days(time, now) = (now - time) / 86_400.0

    # [[path, reason], ...] — everything a run would delete right now.
    def plan(now: Time.now)
      rotated_logs(now) + issue_dirs(now) + workspaces(now)
    end

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

    def workspaces(now)
      root = Agent::Paths.workspace_root
      return [] unless Dir.exist?(root)
      Dir.children(root).sort.filter_map do |name|
        next unless name.match?(AGENT_SLUG)
        path = File.join(root, name)
        next unless File.directory?(path)
        next unless age_days(File.mtime(path), now) > WORKSPACE_DAYS
        [path, "agent workspace idle #{age_days(File.mtime(path), now).round} days (keep #{WORKSPACE_DAYS})"]
      end
    end

    def apply(entries)
      entries.each { |path, _reason| FileUtils.rm_rf(path) }
      entries.length
    end
  end
end

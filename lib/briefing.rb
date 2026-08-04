require 'fileutils'

# The morning briefing's status files.
#
# openclaw's morning briefing (`openclaw-workspace/scripts/morning-briefing.md`)
# renders a section per scheduled job by reading a one-file-per-job status report
# out of the workspace's `data/` directory. Each file's first line is
# `Last run: <YYYY-MM-DD>`, and the briefing skips a section whose date is not
# today — that is how a job that silently stopped running disappears instead of
# reporting stale numbers.
#
# Until the agent producers took these jobs over, the *cron prompt* wrote the
# file: the openclaw session ran `dev <thing>`, parsed its stdout, and wrote the
# summary. A producer has no such session — it runs the command and nothing else
# — so the command now writes its own status file. That is the better home
# anyway: the code that knows what happened writes what happened, instead of a
# prose runbook re-deriving it from stdout with a regex.
#
# Writes are BEST EFFORT and never abort the caller. Docker was pruned whether
# or not the briefing hears about it, and a full disk or a missing workspace must
# not turn a successful chore into a failed producer run.
module Briefing
  DATA_DIR = File.expand_path("~/code/openclaw/openclaw-workspace/data").freeze

  module_function

  def today = Time.now.strftime("%Y-%m-%d")

  # `body` is the full file content; the caller owns the format because the
  # briefing parses each file differently. Written atomically (tmp + rename) so
  # a briefing reading at 6:50 while a job writes never sees half a file.
  def write(name, body)
    path = File.join(DATA_DIR, name)
    return false unless Dir.exist?(DATA_DIR)
    tmp = "#{path}.tmp"
    File.write(tmp, body.end_with?("\n") ? body : "#{body}\n")
    FileUtils.mv(tmp, path)
    true
  rescue => e
    warn "briefing: could not write #{name}: #{e.class}: #{e.message}"
    false
  end
end

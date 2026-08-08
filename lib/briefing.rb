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
# Half the jobs never became producers, though. `slow-query-review`,
# `daily-perf-prs` and `platform-memory-improvement` are agent SESSIONS following
# a playbook, and their playbooks ended by telling the session to write this file
# with its own hands — into a directory the autonomous-session guardrail
# (`agent/instructions.md` §3) forbids editing, with no remedy the guardrail
# offers that fits (ISS-1022: "clone what you need into your workspace"
# accomplishes nothing when the briefing reads the original path). Every night,
# on every runner, a session had to decide unaided whether to obey the playbook
# or the guardrail, and the literal-minded reading — refuse, and let the section
# go dark — is the correct one.
#
# `dev agent status-file <key> --write FILE` is the resolution: a session runs a
# COMMAND, the way it runs `dev agent playbook --write` rather than editing the
# playbook store by hand, and the guardrail stays flat. That is why this module
# now owns the registry below rather than taking a filename from its caller —
# the command needs something to validate a key against, and a filename passed in
# from outside is a typo away from a file the briefing never reads.
#
# Writes are BEST EFFORT and never abort the caller. Docker was pruned whether
# or not the briefing hears about it, and a full disk or a missing workspace must
# not turn a successful chore into a failed producer run. The CLI, whose caller
# was TOLD to record something, reports the false rather than swallowing it.
module Briefing
  DATA_DIR = File.expand_path("~/code/openclaw/openclaw-workspace/data").freeze

  # Job key -> the filename the briefing reads for it. CLOSED on purpose: an
  # unregistered key is refused rather than written, because the failure it would
  # otherwise produce is the one this whole mechanism exists to prevent — a file
  # written successfully, under a name nothing reads, with no error anywhere. A
  # new job registers its key in the same change that adds the job.
  #
  # Keys are the playbook key (`slow-query-review`) or the chore's command name
  # (`docker-prune`), which is what the session running it already knows itself
  # as. The filenames are not derivable from them — `browserslist-update` writes
  # `browserslist-status.md` and `platform-memory-improvement` writes a file with
  # no `-status` at all — which is the other half of why this table exists.
  FILES = {
    "aidirs-prune" => "aidirs-prune-status.md",
    "browserslist-update" => "browserslist-status.md",
    "daily-perf-prs" => "daily-perf-prs-status.md",
    "docker-prune" => "docker-prune-status.md",
    "platform-memory-improvement" => "platform-memory-improvement.md",
    "slow-query-review" => "slow-query-review-status.md",
  }.freeze

  # The briefing's own parse rule, in one place. It dates a section by the first
  # line and skips anything it cannot date or that is not today, so a body whose
  # header is malformed is not "slightly off" — it is invisible, exactly like a
  # job that stopped running. Everything after the date is per-file (` — ok`,
  # ` 03:47 ET`, ` (check only, nothing pushed)`) and belongs to the caller.
  HEADER_RE = /\ALast run: (\d{4}-\d{2}-\d{2})\b/.freeze

  class UnknownKey < ArgumentError; end

  module_function

  def today = Time.now.strftime("%Y-%m-%d")

  def keys = FILES.keys

  def known?(key) = FILES.key?(key.to_s)

  def file_for(key)
    FILES.fetch(key.to_s) do
      raise UnknownKey, "no briefing status file is registered for `#{key}`. Known keys: #{keys.join(', ')}."
    end
  end

  def path_for(key) = File.join(DATA_DIR, file_for(key))

  # The date the briefing would read off this body, or nil when it could not read
  # one at all.
  def header_date(body)
    HEADER_RE.match(body.to_s)&.captures&.first
  end

  # The current contents, or nil when the job has never written one (or the
  # workspace is not on this machine).
  def read(key)
    path = path_for(key)
    File.exist?(path) ? File.read(path) : nil
  end

  # `body` is the full file content; the caller owns the format because the
  # briefing parses each file differently. Written atomically (tmp + rename) so
  # a briefing reading at 6:50 while a job writes never sees half a file.
  def write(key, body)
    path = path_for(key)
    return false unless Dir.exist?(DATA_DIR)
    tmp = "#{path}.tmp"
    File.write(tmp, body.end_with?("\n") ? body : "#{body}\n")
    FileUtils.mv(tmp, path)
    true
  rescue UnknownKey
    raise
  rescue => e
    warn "briefing: could not write #{key}: #{e.class}: #{e.message}"
    false
  end
end

require 'agent/paths'

# `~/code/.claude` — the directory every Claude Code session on this machine
# resolves its rules, skills and subagents through, and the one piece of runner
# provisioning that had been left to a human to remember (ISS-615).
#
# WHAT WAS ACTUALLY BROKEN. `~/code/CLAUDE.md` is loaded into every session on
# this fleet, and it points at `.claude/` more than a dozen times: the whole
# "Development Guidelines" section ("Read all relevant `.claude/rules/*.mdc`
# files before writing code"), `.claude/tools/browse/README.md`, and
# `.claude/.impeccable.md`. Provisioning created the `~/code/CLAUDE.md ->
# claude/CLAUDE.md` symlink and stopped there, so on every runner `~/code/.claude`
# did not exist and none of those paths resolved.
#
# THE COST IS NOT THE DEAD DOC LINKS, IT IS EVERYTHING ELSE IN THAT DIRECTORY.
# The `claude` repo is not a docs folder that happens to be named after the tool
# — it IS a Claude Code config directory: `rules/`, `skills/`, `agents/`,
# `settings.json`, `settings.local.json`, `.impeccable.md`. Claude Code
# discovers those by looking for `.claude/` in the cwd and its ancestors, and
# `claude` (no dot) is not a name it has ever looked for. Measured on
# agr-1d2a3bc2ac55490a8da14d68e2035081 by running a session under a
# `.claude -> claude` symlink and again without one:
#
#   with the link     9 project skills and 7 project subagents load
#   without it        zero of either — only Claude Code's built-ins
#
# So every session CLAUDE.md instructed to "use the `repo-map` skill", the
# `session-db` skill, `releasing-libraries`, `writing-as-mike` or
# `context-handoff` was being told to use something that was not there. Nothing
# errored, which is the entire reason this survived: a skill that does not exist
# is not a failure a session can see, it is a paragraph of CLAUDE.md that
# quietly does nothing.
#
# WHY THE TICK CREATES IT RATHER THAN REPORTING IT. Agent::Toolchain reports
# instead of fixing because devops cannot `brew install` on your behalf. This is
# the opposite case: the fix is one symlink, it is idempotent, and it is exactly
# the class of thing that a per-machine manual step loses. A provisioning step
# nobody runs is the SHAPE of this bug, not the fix for it.
#
# WHAT IT WILL NEVER DO IS DELETE ANYTHING. `~/code/.claude` that already exists
# and points somewhere else is a human's deliberate choice — a second config
# tree, a checkout under the dotted name — and unlinking it to "repair" the
# machine would destroy configuration this module cannot read and did not
# create. Every such case is reported and left exactly as found.
module Agent
  module ClaudeConfig
    # :ok           the link (or a directory in its place) already resolves to
    #               the claude repo. Nothing to do.
    # :linked       it was absent and this call created it.
    # :absent       it is absent and this is a read-only `state` call. The next
    #               tick creates it.
    # :conflict     something else is there. Reported, never touched.
    # :missing_repo there is no claude checkout to link to. A dangling symlink
    #               would be strictly worse than none, so none is created.
    # :failed       the symlink call itself failed (permissions, read-only fs).
    Result = Struct.new(:state, :link, :repo, :target, :message, keyword_init: true) do
      def ok? = %i[ok linked].include?(state)
      def linked? = state == :linked

      # The literal command, for the same reason Agent::Toolchain::Tool#install
      # is a command and not a description: the one question a broken machine
      # asks is "what do I type".
      def remedy
        case state
        when :absent
          "the next `dev agent tick` creates it — or now: `ln -s #{target} #{link}`"
        when :conflict
          "inspect #{link} by hand: it exists and does not resolve to #{repo}. " \
            "Nothing in the tick will remove it."
        when :missing_repo
          "clone it: `gh repo clone mbryzek/claude #{repo}`"
        when :failed
          "#{link} could not be created: #{message}"
        end
      end
    end

    module_function

    # Agent::Paths owns the resolution so the test seam (DEV_AGENT_CLAUDE_REPO)
    # moves the link with the repo, and so this can never disagree with the
    # `claude_repo` the pre-push hook and the session env already use.
    def repo = Agent::Paths.claude_repo

    def link = File.join(File.dirname(repo), ".claude")

    # RELATIVE, deliberately: `~/code/.claude -> claude`, not an absolute path
    # into someone's home. The runners and Mike's machine have different
    # usernames, and a relative link is the one that survives a home directory
    # being moved, copied or restored under a different name.
    def target = File.basename(repo)

    # Read-only. `dev agent doctor` must be able to report this machine without
    # changing it — a doctor with a side effect cannot tell you what state you
    # were in when you ran it.
    def state
      link_path = link
      repo_path = repo

      unless File.directory?(repo_path)
        return result(:missing_repo, "#{repo_path} is not a directory — nothing to link to")
      end
      return result(:ok, "#{link_path} -> #{repo_path}") if resolves_to_repo?(link_path, repo_path)
      if File.symlink?(link_path) || File.exist?(link_path)
        return result(:conflict, "#{link_path} already exists as #{describe(link_path)} and does not " \
                                 "resolve to #{repo_path} — left untouched")
      end

      result(:absent, "#{link_path} does not exist")
    end

    # Idempotent, and the only call here that writes anything.
    def ensure_link
      current = state
      return current unless current.state == :absent

      File.symlink(target, link)
      result(:linked, "created #{link} -> #{target}")
    rescue Errno::EEXIST
      # Another process created it between `state` and here. The link it made is
      # the link this one wanted, so re-read rather than reporting a failure
      # that would escalate into an issue about a machine that is now correct.
      state
    rescue SystemCallError => e
      result(:failed, e.message)
    end

    # ---- internals ----

    def result(state, message)
      Result.new(state: state, link: link, repo: repo, target: target, message: message)
    end

    # realpath on BOTH sides: `~/code` is itself under a symlinked home on some
    # macOS setups (/var vs /private/var), and a string comparison would call a
    # correct machine broken. A dangling link raises here, which is exactly the
    # "does not resolve" answer.
    def resolves_to_repo?(link_path, repo_path)
      File.realpath(link_path) == File.realpath(repo_path)
    rescue SystemCallError
      false
    end

    def describe(path)
      return "a symlink to #{File.readlink(path)}" if File.symlink?(path)
      return "a directory" if File.directory?(path)
      "a file"
    end
  end
end

require 'agent/paths'

# The prompt fed to a session on stdin (design §4.3.2). Four parts, in this
# order:
#
#   1. Standing instructions — devops/agent/instructions.md, versioned in git
#      and reviewed like code. Everything the outcome protocol depends on lives
#      there, not here.
#   2. The issue body.
#   3. The PLAYBOOK, when the body points at one — read from this runner's devops
#      checkout at claim time, not copied into the issue when it was filed
#      (ISS-505). Absent for every issue that carries its brief inline.
#   4. EVERY issue comment, oldest first.
#
# Part 4 is not optional context — it is how the loops close. A `needs_input`
# issue returns to `open` when Mike answers as a comment, and the next attempt
# only works because it reads that comment; review feedback flows identically
# (§4.4.1). Dropping comments would silently break both loops while everything
# still looked like it ran. It stays LAST for the same reason it is sorted
# oldest-first: the most recent instruction must be the last thing read, which is
# why the playbook goes above it and not below.
#
# The assignment block between the instructions and the body is executor state
# the session cannot discover for itself: which directory is its workspace,
# which branch to use, and whether this is a fresh attempt or a resume.
module Agent
  module Prompt
    module_function

    def instructions
      path = Agent::Paths.instructions_file
      raise "standing instructions not found: #{path}" unless File.file?(path)
      File.read(path)
    end

    def build(issue:, comments:, slug:, workspace:, resume_repo: nil, playbook: nil)
      [
        instructions.strip,
        assignment(issue: issue, slug: slug, workspace: workspace, resume_repo: resume_repo),
        issue_section(issue),
        playbook_section(playbook),
        comments_section(comments),
      ].compact.join("\n\n---\n\n") + "\n"
    end

    def assignment(issue:, slug:, workspace:, resume_repo: nil)
      lines = []
      lines << "# Your assignment"
      lines << ""
      lines << "- Issue: ISS-#{issue['number']} — #{issue['title']}"
      lines << "- Category: #{issue['category']}   Severity: #{issue['severity'] || 'unset'}"
      lines << "- Workspace (your ONLY writable working directory): #{workspace}"
      lines << "- Branch to use in every repo you touch: `#{slug}` — **verbatim**"
      lines << "- PR title MUST start with `ISS-#{issue['number']}: `"
      lines << ""
      # Restated here, next to the name itself, because CLAUDE.md independently
      # tells every session to name its branch after the feature and a session
      # reading both was choosing between two rules — which is exactly how
      # ISS-354 opened its PR on `exp-rpt-notif-inv` and classified as if it had
      # done nothing (ISS-365).
      lines << "**Do not rename the branch.** CLAUDE.md tells interactive sessions to name a branch"
      lines << "after the feature; that rule does not apply to you. `#{slug}` is recorded on your lease"
      lines << "and the executor classifies your outcome by looking it up — a descriptively-named"
      lines << "branch is one the executor cannot find, and good work on it reads as no work at all."
      lines << ""
      if resume_repo
        lines << "**This is a RESUME, not a fresh attempt.** `#{resume_repo}` is already cloned in your"
        lines << "workspace, checked out on `#{slug}` and rebased onto `origin/main`. An open PR exists"
        lines << "on that branch. Do NOT open a second PR and do NOT create a new branch: read the"
        lines << "comments below for what is being asked, address it, rerun codegen, push, and the PR"
        lines << "updates in place. Close the issue out with `dev issues status` as usual."
      else
        lines << "Your workspace is empty. Clone every repo you need into it (`gh repo clone <owner>/<repo>"
        lines << "#{workspace}/<repo>`), create branch `#{slug}` in each from the latest `origin/main`, and"
        lines << "work there. Never edit a checkout under ~/code outside this workspace."
      end
      lines.join("\n")
    end

    def issue_section(issue)
      <<~SECTION.strip
        # ISS-#{issue['number']}: #{issue['title']}

        #{issue['body'].to_s.strip}
      SECTION
    end

    # nil when the issue carries no pointer, which `build` drops rather than
    # rendering an empty section — a heading with nothing under it reads as "your
    # playbook is missing" to a session whose issue never had one.
    #
    # The abstract in the issue body above is a summary of exactly this text, and
    # saying which one wins matters: the body was written the night the issue was
    # filed, this was read moments ago.
    def playbook_section(playbook)
      return nil if playbook.nil?
      <<~SECTION.strip
        # Playbook — #{playbook.label}

        The procedure for this issue, resolved from the platform's playbook store at the
        moment the issue was claimed — NOT a copy frozen when the issue was filed. Where it
        and the abstract in the issue body differ, THIS wins. The version above is recorded
        as a comment on the issue, and the store is append-only, so this exact text stays
        readable after the playbook is edited.

        #{playbook.text}
      SECTION
    end

    # Oldest first, so the thread reads forward and the most recent instruction
    # — which is usually the one that re-opened the issue — is last.
    def comments_section(comments)
      list = Array(comments).sort_by { |c| c["created_at"].to_s }
      return "# Issue comments\n\n(none)" if list.empty?
      body = list.map do |c|
        author = c.dig("user", "name") || c.dig("user", "id") || c["author"] || "unknown"
        "## #{c['created_at']} — #{author}\n\n#{c['body'].to_s.strip}"
      end.join("\n\n")
      "# Issue comments (oldest first — read all of them)\n\n#{body}"
    end
  end
end

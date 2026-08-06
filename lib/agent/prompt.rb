require 'agent/credentials'
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

    def build(issue:, comments:, slug:, workspace:, resume_repo: nil, prepared_repos: [], playbook: nil,
              credentials: Agent::Credentials.check)
      [
        instructions.strip,
        assignment(issue: issue, slug: slug, workspace: workspace, resume_repo: resume_repo,
                   prepared_repos: prepared_repos, credentials: credentials),
        issue_section(issue),
        playbook_section(playbook),
        comments_section(comments),
      ].compact.join("\n\n---\n\n") + "\n"
    end

    def assignment(issue:, slug:, workspace:, resume_repo: nil, prepared_repos: [],
                   credentials: Agent::Credentials.check)
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
      elsif prepared_repos.to_a.any?
        # The repos the issue named, already materialized (ISS-562). Named
        # explicitly rather than left for the session to discover, because a
        # session that does not know the checkout is there clones a second copy
        # beside it and works in the one the executor is not watching.
        lines << "**The repos this issue names are already cloned in your workspace**, each on branch"
        lines << "`#{slug}` off the latest `origin/main`: #{prepared_repos.map { |r| "`#{r}`" }.join(', ')}."
        lines << "Work in those checkouts — do not re-clone them and do not rename the branch. If you need"
        lines << "a repo that is not listed, clone it into the workspace yourself (`gh repo clone"
        lines << "<owner>/<repo> #{workspace}/<repo>`) and create the same branch in it. Never edit a"
        lines << "checkout under ~/code outside this workspace."
      else
        lines << "Your workspace is empty. Clone every repo you need into it (`gh repo clone <owner>/<repo>"
        lines << "#{workspace}/<repo>`), create branch `#{slug}` in each from the latest `origin/main`, and"
        lines << "work there. Never edit a checkout under ~/code outside this workspace."
      end
      lines << "" << credentials_section(credentials)
      lines.join("\n")
    end

    # Which external-API credentials THIS runner holds, stated before the
    # session plans rather than discovered halfway through it (ISS-570).
    #
    # This is executor state in the same sense the workspace path is: a fact
    # about the machine the session cannot establish for itself, because a
    # credential's absence looks exactly like a credential it has not thought to
    # look for. The ISS-565 session wrote a Claude-API probe, could not run one
    # request, and only found that out after the code existed — by which point
    # "verify it against the API" had already been treated as in scope.
    #
    # PRESENCE ONLY. `Agent::Credentials.check` carries no values by
    # construction, so nothing here can render a secret into prompt.md — which
    # is written to the log tree and is exactly the sort of file that ends up
    # quoted in an issue comment.
    def credentials_section(found)
      lines = ["## Live external-API credentials on this runner", ""]
      Array(found).each do |f|
        if f.present?
          lines << "- `#{f.name}` — **available in your environment** (#{f.explanation}). Needed for " \
                   "#{f.credential.required_by}."
          lines << "  Pass it explicitly to whatever you are verifying — e.g. " \
                   "`#{f.credential.usage_example}`."
          lines << "  **Never print, echo, commit, or paste it** into a PR, an issue comment, a plan or a " \
                   "test fixture."
        else
          lines << "- `#{f.name}` — **NOT available on this runner** (#{f.explanation})."
          lines << "  Anything in your assignment that asks you to verify behaviour against the live API " \
                   "this key is for (#{f.credential.required_by}) **cannot be closed out here**. Say so up " \
                   "front, do the offline work in full, state plainly in the PR which part is unverified, " \
                   "and file it with `dev issues workaround`. Do not design against the documentation and " \
                   "then report it as verified."
        end
      end
      # A footer rather than a per-credential line: this is a fact about the
      # PROCESS the environment is handed to, not about any one key. `claude`
      # resolves ANTHROPIC_API_KEY as its own credential, so copying anything
      # into it moves the session off Mike's subscription onto per-token billing
      # with nothing in the output to say so.
      lines << ""
      lines << "Never copy any of these into `ANTHROPIC_API_KEY` — that variable reconfigures the " \
               "`claude` CLI you are running inside."
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

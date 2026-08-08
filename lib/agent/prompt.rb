require 'agent/credentials'
require 'agent/paths'
require 'agent/prod_read'

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

    def build(issue:, comments:, slug:, workspace:, resume_repo: nil, prepared_repos: [], continued_repos: [],
              playbook: nil, credentials: Agent::Credentials.check, prod_read: Agent::ProdRead.check)
      [
        instructions.strip,
        assignment(issue: issue, slug: slug, workspace: workspace, resume_repo: resume_repo,
                   prepared_repos: prepared_repos, continued_repos: continued_repos, credentials: credentials,
                   prod_read: prod_read),
        issue_section(issue),
        playbook_section(playbook),
        comments_section(comments),
      ].compact.join("\n\n---\n\n") + "\n"
    end

    def assignment(issue:, slug:, workspace:, resume_repo: nil, prepared_repos: [], continued_repos: [],
                   credentials: Agent::Credentials.check, prod_read: Agent::ProdRead.check)
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
      lines << "after the feature; that rule does not apply to you. `#{slug}` is derived from this issue"
      lines << "and the executor classifies your outcome by looking it up — a descriptively-named"
      lines << "branch is one the executor cannot find, and good work on it reads as no work at all."
      lines << ""
      # The one thing the branch rule on its own cannot express (ISS-657): a run
      # that produces several INDEPENDENT PRs cannot put them on one branch
      # without stacking them, which these squash-merge repos forbid. Stated in
      # the assignment beside the name itself, for the same reason the sentence
      # above is: a session weighing "verbatim" against a playbook that demands
      # disjoint PRs improvises, and the ISS-651 run did.
      lines << "**More than one PR?** `#{slug}` carries the primary one; name every additional PR's"
      lines << "branch `#{slug}_<suffix>` (≤19 chars, off latest `origin/main`, disjoint files, never"
      lines << "stacked). A branch that does not START with `#{slug}` is invisible to the executor."
      lines << ""
      # Which NUMBER those PRs carry is the other half, and it is not a branch
      # question (ISS-759): several PRs that are one change stay on this issue,
      # several INDEPENDENT changes each need their own, or none of them can be
      # closed out, deployed, verified or auto-merged apart from the others.
      lines << "**One change spread across repos?** Title them all `ISS-#{issue['number']}: ` and record the"
      lines << "extras with `dev issues fix #{issue['number']} --url ...`. **Several INDEPENDENT changes?** Give"
      lines << "each its OWN issue number BEFORE opening its PR — `dev issues split #{issue['number']} --title ...`"
      lines << "— then title and close out each one against the number it prints. See §1 of the"
      lines << "standing instructions above."
      lines << ""
      if resume_repo
        lines << "**This is a RESUME, not a fresh attempt.** `#{resume_repo}` is already cloned in your"
        lines << "workspace, checked out on `#{slug}` with the latest `origin/main` MERGED in (§6 — never"
        lines << "rebased, so your push is an ordinary one and needs no force). An open PR exists"
        lines << "on that branch. Do NOT open a second PR and do NOT create a new branch: read the"
        lines << "comments below for what is being asked, address it, rerun codegen, push, and the PR"
        lines << "updates in place. Close the issue out with `dev issues status` as usual. That bars"
        lines << "re-opening THIS work on a fresh branch — not a genuinely independent additional PR,"
        lines << "which still follows the `#{slug}_<suffix>` rule above."
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
        lines.concat(continued_section(slug, continued_repos, issue))
      else
        lines << "Your workspace is empty. Clone every repo you need into it (`gh repo clone <owner>/<repo>"
        lines << "#{workspace}/<repo>`), create branch `#{slug}` in each from the latest `origin/main`, and"
        lines << "work there. Never edit a checkout under ~/code outside this workspace."
      end
      lines << "" << credentials_section(credentials)
      lines << "" << prod_read_section(prod_read)
      lines.join("\n")
    end

    # The branch was ALREADY THERE when the executor prepared these checkouts, so
    # this attempt is standing on somebody's commits (ISS-767).
    #
    # Reachable on the ordinary retry path now that the branch is derived from the
    # issue instead of drawn at random: attempt 2 computes the name attempt 1
    # pushed. That is the intent — resume by default — but only if the session
    # KNOWS. Told nothing, it reads the "already cloned, off the latest
    # origin/main" line above, sees commits it did not write, and its two guesses
    # are both wrong: open a second PR on work that already has one, or rebase
    # away a predecessor's diff.
    #
    # It deliberately does NOT assert what the earlier commits mean. The executor
    # knows only that refs exist; whether they are an open PR, a merged one, or a
    # crashed attempt that never opened anything is one `gh pr list` away for the
    # session, and guessing here would be a confident wrong answer in the case
    # that matters most — a diff a human already rejected.
    def continued_section(slug, continued_repos, issue)
      repos = Array(continued_repos)
      return [] if repos.empty?

      ["",
       "**`#{slug}` ALREADY EXISTED** in #{repos.map { |r| "`#{r}`" }.join(', ')} — it is checked out with an",
       "earlier attempt's commits on it, NOT freshly branched from `origin/main`. The branch name is",
       "derived from this issue, so a retry lands here by design. Before you write anything, run",
       "`gh pr list --head #{slug} --state all` in each of those checkouts and act on what you find:",
       "an OPEN PR is yours to update in place (never open a second one — see §6); a MERGED one means",
       "the work already landed, so merge latest `origin/main` in (§6, never rebase) and the old diff is",
       "already there; a CLOSED-unmerged one is work a",
       "human rejected, so read the review before building on it; no PR at all is an attempt that died",
       "mid-flight, and continuing it is usually right. Say in your PR description which of these it was.",
       "Record any additional PR with `dev issues fix #{issue['number']} --url ...`."]
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
          # ISS-1037. This used to read "available in your environment", and it
          # was true: every session held every key for its whole life, so a
          # `ps -Eax`, an inherited dev server, or a stray `pgrep -fl` could
          # sweep one up without the session doing anything wrong (ISS-961). The
          # value is no longer there. What the session is told is unchanged in
          # the part ISS-570 cares about — this machine HAS the key, so work that
          # needs it can be closed out here — and changed in where it lives.
          lines << "- `#{f.name}` — **available on this runner, and deliberately NOT in your " \
                   "environment** (#{f.explanation}). Needed for #{f.credential.required_by}."
          lines << "  Ask for it per command, and it exists only in that command's own process:"
          lines << ""
          lines << "        dev agent credential exec --name #{f.name} -- \\"
          lines << "          /bin/zsh -c '#{f.credential.usage_example}'"
          lines << ""
          # The quoting is the whole failure mode, so it is stated at the point
          # of use rather than left to §4. Double quotes make the session's own
          # shell expand the reference to the empty string before `dev` runs, and
          # an unauthenticated NerdGraph query answers an empty result set rather
          # than a 401 — a graph that reads as healthy and was never queried
          # (ISS-635). The command refuses when it cannot see the name in the
          # argv, which is exactly what that mistake leaves behind.
          lines << "  **SINGLE quotes around the inner command**, so the shell that expands `$#{f.name}` " \
                   "is the one that has it. Double quotes expand it to nothing before `dev` starts, and " \
                   "an unauthenticated request usually answers an empty result rather than an error. The " \
                   "command refuses when it cannot see `#{f.name}` in what you gave it."
          lines << "  **Never print, echo, commit, or paste it** into a PR, an issue comment, a plan or a " \
                   "test fixture."
          # ISS-961. The line above is what a session obeys and it was not
          # enough, because inlining a value into a command reads as none of
          # those four verbs — and the `exec` example right above it is a shell
          # command, which is the moment the question actually arises. Stated per
          # credential, with the variable's own name in it, so the correct form
          # is the thing on screen at the point of use.
          lines << "  **And never write the value into a command line — pass `$#{f.name}`, never what it " \
                   "resolves to.** Several sessions share this runner as one user, and `ps` shows every " \
                   "argument of every one of their processes to all the others — so a sibling's routine " \
                   "process listing sweeps an inlined key into ITS transcript, which outlives this machine. " \
                   "`exec` keeps the value in an environment instead, for one command's lifetime. See §4."
        else
          lines << "- `#{f.name}` — **NOT available on this runner** (#{f.explanation})."
          lines << "  Anything in your assignment that asks you to verify behaviour against the live API " \
                   "this key is for (#{f.credential.required_by}) **cannot be closed out here**. Say so up " \
                   "front, do the offline work in full, state plainly in the PR which part is unverified, " \
                   "and file it with `dev issues workaround`. Do not design against the documentation and " \
                   "then report it as verified."
        end
      end
      # ISS-1028. Stated once, as a footer, because it is a fact about the MACHINE
      # rather than about any one key — and stated at all because the per-credential
      # rule above, read alone, implies a protection that does not exist. "Never
      # write the value into a command line" is true, but a session takes from it
      # that the ENVIRONMENT is the safe place to keep a credential. It is not:
      # `ps -Eax` prints a sibling's whole environment to any process with the
      # same uid, for the whole life of the session, and the env repo these values
      # are read out of is unlocked on disk under that same uid. Measured on a
      # runner: 88 of 770 processes disclosing, 13 of them carrying
      # PLAYBOOK_CLAUDE_KEY. A session that obeys
      # the argv rule perfectly still holds nothing back from its siblings. So the
      # honest statement, plus the two rules that survive it: the durable artifact
      # is the boundary, and harvesting is the way a credential reaches one.
      lines << ""
      lines << "This runner is SHARED and the isolation boundary is the MACHINE, not your session: every " \
               "other session runs as the same user and can already read these keys out of your " \
               "environment (`ps -Eax`), out of your command lines (`ps -U`), and off disk. macOS " \
               "withholds only an Apple platform binary's environment, so the processes that DO disclose " \
               "are `claude`, `node`, `ruby`, `java`, `vite` — every process a session actually runs. " \
               "Hiding a key from a sibling is not possible and is not the rule. The rule is that it must never " \
               "reach a DURABLE artifact — a transcript, a PR, an issue comment, a plan, a commit, a test " \
               "fixture — and that you never run a command that harvests one: no `ps -E`, no `ps auxww`, " \
               "no `pgrep -fl`, no bare `env`. See §4 (ISS-1028)."
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

    # Which production APIs this runner can READ, stated beside the credentials
    # for the same reason they are (ISS-1062).
    #
    # The ISS-1056 session had this exact access and did not know it. It read §3's
    # "never touch the production database", found no acumen key in the
    # credentials section above, and concluded — reasonably, from what it was
    # told — that production was unreachable. So it inferred a list of stale enum
    # values from git history and shipped a migration naming them, while the
    # producer's own six-second probe sat one command away.
    #
    # That is why this is a section and not a line in the standing instructions.
    # A capability a session is not told about does not exist, and the shape of
    # the mistake is identical to ISS-565's: the run did not fail, it quietly
    # lowered what it claimed to have established.
    def prod_read_section(found)
      lines = ["## Production data you can READ on this runner", ""]
      lines << "An issue that cites an on-screen or per-row observation is CHECKABLE. Check it — do not"
      lines << "reconstruct it from the repos and ship the inference (ISS-1062)."
      lines << ""
      lines << "This is not a relaxation of §3. §3 forbids the production DATABASE and still does;"
      lines << "`dev prod get` sends one authenticated GET against the product's own API and cannot send"
      lines << "anything else. There is no write form of this command."
      lines << ""
      Array(found).each do |f|
        t = f.target
        if f.present?
          lines << "- **`#{t.app}`** (#{t.host}) — **readable** as #{f.explanation}. Use it for #{t.answers}."
          lines << ""
          lines << "        #{t.example}"
          lines << ""
          # A stored session EXPIRES, unlike an API key, and `ProdRead.check`
          # deliberately does not spend a network round-trip finding out (see its
          # module comment). So the confirming call is named here, at the point
          # the session decides whether to rely on it.
          lines << "  Confirm it in one call before you rely on it — `dev prod get --app #{t.app} #{t.confirm_path}`."
          t.guardrails.each { |g| lines << "  - #{g}" }
        else
          lines << "- **`#{t.app}`** (#{t.host}) — **NOT readable on this runner** (#{f.explanation}). To provide it, " \
                   "#{t.how_to_provide}."
          lines << "  Anything in your assignment that asks you to confirm an observation against #{t.product} " \
                   "**cannot be confirmed here**. Say so up front, do the offline work in full, state plainly in " \
                   "the PR which part is INFERRED rather than observed, and file it with `dev issues workaround`."
        end
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

require 'agent/api'
require 'agent/github'
require 'prs/deploy'

# Has the code an issue is BLOCKED ON actually landed — on main, and then in
# production?
#
# The tracker answers that with a status, and in this fleet the status lies. A
# `blocked_by` edge stops holding its dependent back the moment the blocker
# reaches `fixed` — documented server-side as "that is when the blocker's PR is
# merged and the code the dependent builds on exists". It is not: the close-out
# contract in agent/instructions.md §1 has every session record `fixed` the
# moment its PR is READY, which is before anybody has merged anything, and the
# fleet files follow-up issues far faster than PRs get merged (devops had eleven
# open PRs from a single day when ISS-649 was filed).
#
# ISS-633 went to `fixed` at 09:06 with devops#359 still open. ISS-644, whose
# body said in as many words that it depended on that PR merging first, was
# dispatched 24 minutes later and had to invent a merge order — it carried the
# dependency's commit as its base and shipped a substantively stacked PR, which
# CLAUDE.md forbids. That is ISS-649, and an edge recorded with `dev issues
# block` would NOT have prevented it: the edge would have been unblocking the
# whole time.
#
# So the dispatch gate asks GitHub rather than the status. That read lives out
# here rather than in the platform for the same reason the deploy-readiness
# decision does (`dev issues reconcile`): it needs an external signal the
# backend has no business reaching for.
#
# MERGED IS NOT LIVE, and that is the second half (ISS-1097). A dependent does
# not always merely BUILD on its blocker — a follow-up on a crawler fix, and the
# club_backfill retries are a standing source of them, can only be tested once
# the pod is running the fix. ISS-1024 said so in as many words: "Once workers#207
# is merged AND the workers deploy is live, retry the held windows. Retrying
# BEFORE the fix is live only burns four more attempts." The gate read the first
# half, woke it at 16:09 with #207 merged at 16:08 and the newest workers tag at
# 0.1.77 (= #206), and the session that claimed it four minutes later could do
# nothing at all.
#
# So a blocker has LANDED only when its fix PR merged AND the merge commit is
# contained in what its repo has released. Both halves are asked of GitHub, and
# the second reuses Prs::Deploy — the same "has this actually shipped" the
# cross-repo merge check runs on (ISS-758) — rather than a second notion of what
# a release is.
#
# NOT the blocker's STATUS, at either half. `fixed -> deployed -> verified` is a
# one-way ladder a session can walk by hand, and ISS-1012 reached `verified` at
# 16:03 for a PR that merged at 16:08 — five minutes in the future. Any check
# reading "is it at deployed-or-better" would have cleared on that. Release
# evidence is a fact about a commit; a rung is a claim about one.
#
# FAIL OPEN, everywhere. `gh` missing, a rate limit, an unreadable blocker, a
# fix that is a document rather than a PR, a release state that could not be
# read — every unknown dispatches. A dependency check that stalls the whole
# queue whenever GitHub is unreachable is a worse failure than the one it exists
# to prevent, and it would be silent.
module Agent
  module Dependency
    # The statuses at which a blocker stops holding its dependents back, mirroring
    # InternalIssueLinksDao.UnblockingStatuses. Terminal by the tracker's reckoning
    # — which is precisely what this module does not take at face value.
    SHIPPED_STATUSES = %w[fixed deployed verified dismissed].freeze

    # A blocker nobody is ever going to ship. The tracker treats it as unblocking
    # and so does this: the dependent is on its own, and deferring it would be
    # deferring on work that will never arrive.
    ABANDONED_STATUS = "dismissed".freeze

    # Group 1 is the REPO, which is what the release check asks GitHub about: a
    # fix url is the only place the repo a blocker shipped in is written down.
    FIX_PR_URL = %r{\Ahttps://github\.com/[^/]+/([^/]+)/pull/\d+}

    # The release check asks for the newest RELEASE TAG, never a live prod probe.
    # Two reasons, and the first is decisive: this runs on an agent runner, which
    # has no kubeconfig — the very repo in the incident above (`workers`) is a
    # docker_k8s app with no HTTP version endpoint, so the probe that `dev deploy
    # status` uses answers nothing here (ISS-904). The second is cost: reaching a
    # prod url means loading the apps registry, which shells out to `pkl eval`,
    # on a check that runs every five minutes.
    #
    # The tag is also what the issue asked for and what `dev issues reconcile`
    # already gates `fixed -> deployed` on. What it costs is a release that
    # tagged and then failed to roll out: this would call that shipped. That is a
    # loud, attended event, and the same trade `fetch_release_info` documents.
    NO_LIVE_VERSION = ->(_repo) { nil }

    # How a deferral this module caused is recognised on a timeline, which is
    # where its attempt count is kept. Deliberately a marker in the comment
    # rather than a field: the tracker has nowhere to store a per-issue dispatch
    # counter, and a comment is what a human reads anyway.
    #
    # It lives HERE rather than on Agent::Tick — where it was written and where
    # `DEPENDENCY_DEFER_MARKER` still spells it — because there are two readers
    # now, and they are in different files. The tick writes it when it defers;
    # Agent::DependencyWake reads it to tell a dependency deferral apart from a
    # snooze a human set for some unrelated reason. Same precedent, and same
    # reason, as ERROR_ESCALATE_AT living on Agent::Escalation: one string, two
    # ways to spell it.
    DEFER_MARKER = "Blocked on a dependency that has not merged".freeze

    # What Agent::DependencyWake writes when it lifts a deferral early, and what
    # the platform itself writes on ANY wake — a `dev issues snooze --wake`, the
    # "Wake now" button in playbook-admin, or the DELETE the sweep issues.
    #
    # Both count, because `defer_attempts` below is asking "has this issue been
    # blocked CONTINUOUSLY", and a wake of either kind ends the run. Recognising
    # the platform's string couples this to a sentence the server owns
    # (IssuesService.WakeComment), and the coupling fails SAFE: if that text ever
    # changes, an old run stops being reset and the issue reaches the
    # seven-attempt escalation sooner — which puts it in front of a human, not
    # past one.
    WAKE_MARKER = "Dependency cleared — this issue is no longer waiting on unmerged code".freeze
    PLATFORM_WAKE_MARKER = "Snooze cleared; back in the queue".freeze
    WAKE_MARKERS = [WAKE_MARKER, PLATFORM_WAKE_MARKER].freeze

    # How the comment that established an issue's CURRENT snooze is picked out of
    # its timeline (ISS-975). Every snooze in the system — the dispatcher's
    # deferral, `dev issues snooze`, playbook-admin's button, a session parking
    # its own issue — reaches the same server method, and that method opens with
    # this sentence before appending whatever note the caller passed:
    #
    #   IssuesService.snoozeComment: s"Snoozed until ${WakeTimeFormat.print(until)}."
    #
    # So the LAST comment carrying this string is the one that put the issue to
    # sleep, and whether it also carries DEFER_MARKER is what says whose snooze
    # it is. DEFER_MARKER alone cannot answer that: it stays on the timeline
    # forever, so an issue deferred once reads as deferred for the rest of its
    # life — see Agent::DependencyWake.dependency_deferred?, which is where that
    # cost this fleet four claims in two hours.
    #
    # A third coupling to a sentence the server owns, and it fails SAFE in the
    # same direction as PLATFORM_WAKE_MARKER above: if the wording ever changes,
    # no snooze looks like a deferral, this sweep lifts nothing, and every
    # deferral comes back on the daily expiry that predates ISS-922 — latency,
    # not a snooze undone behind somebody's back.
    PLATFORM_SNOOZE_MARKER = "Snoozed until ".freeze

    module_function

    # The issues this one is waiting on, as the server returns them: one entry per
    # `blocked_by` edge this issue is the SOURCE of, each naming the far end and
    # its status. Read here rather than through bin/dev's `issue_blockers` so the
    # dispatcher keeps working off `lib/` alone.
    def blockers(issue)
      Array(issue["links"])
        .select { |l| l["type"] == "blocked_by" && l["direction"] == "outgoing" }
        .filter_map { |l| l["issue"] }
    end

    # Where a merge commit has got to, memoised per (repo, sha) so a sweep over
    # twenty issues waiting on ONE PR asks GitHub once. Built per pass rather
    # than held on the module: a cache that outlived a pass would remember
    # "not released yet" across the release that fixed it.
    def release_oracle
      cache = {}
      lambda do |repo, sha|
        cache.fetch([repo, sha]) { cache[[repo, sha]] = release_state(repo, sha) }
      end
    end

    # :shipped / :unreleased / :unknown for one merge commit.
    #
    # A repo that publishes NO releases is :shipped, and that is not a fallback —
    # it is the correct answer. devops is the case that matters, and it is the
    # most common blocker repo in this fleet: nothing builds or ships it, every
    # runner fast-forwards its checkout at the top of every tick, so merging IS
    # deploying (which is why instructions.md §3 forbids merging one at all).
    # Waiting for a tag there would park every devops-blocked issue until the
    # daily expiry — undoing ISS-922 for the majority case in the name of a
    # release nobody is ever going to cut. Prs::Deploy tells that apart from a
    # read that failed, which stays :unknown.
    def release_state(repo, sha)
      case Prs::Deploy.state(repo, sha, live_version: NO_LIVE_VERSION)
      when :shipped, :unreleasable then :shipped
      when :unshipped then :unreleased
      else :unknown
      end
    end

    # Where ONE recorded fix url has got to — `[state, pr]` — in the vocabulary
    # both gates read:
    #
    #   :shipped    — merged, and that merge is in the repo's newest release
    #   :unreleased — merged, and demonstrably NOT in it yet
    #   :open       — still open
    #   :closed     — closed without merging
    #   :unknown    — every read that did not answer
    #
    # (`unshipped` adds :working for a blocker that is not terminal at all, which
    # is answered from the tracker's status without asking GitHub anything.)
    #
    # `pr` is nil only when the lookup itself failed, which is an :unknown like
    # any other.
    def fix_state(url, deployed:)
      pr = Agent::Github.pr_by_url(url)
      return [:unknown, nil] if pr.nil?
      return [:open, pr] if Agent::Github.open?(pr)
      return [:closed, pr] if Agent::Github.closed?(pr)
      # A state this file does not recognise, and a merged PR whose merge commit
      # `gh` did not return: both are unknowns, and neither is evidence.
      return [:unknown, pr] unless Agent::Github.merged?(pr)

      [deployed.call(url[FIX_PR_URL, 1], Agent::Github.merge_sha(pr)), pr]
    end

    # Every blocker whose code is NOT live yet, each with the evidence: the
    # blocker's status, how far its fix got, and the PR that says so when there
    # is one. Empty — the overwhelmingly common case, since most issues have no
    # blockers at all — means dispatch.
    def unshipped(issue, use_localhost:, deployed: release_oracle)
      blockers(issue).filter_map do |ref|
        number = ref["number"]
        status = ref["status"]
        # Live work by the tracker's own rule. The server passes these over when it
        # leases, so reaching here means something raced; agreeing with the server
        # costs one branch and cannot false-positive.
        unless SHIPPED_STATUSES.include?(status)
          next { "number" => number, "status" => status, "pr" => nil, "state" => :working }
        end
        next nil if status == ABANDONED_STATUS

        state, pr = unlanded_fix(number, use_localhost: use_localhost, deployed: deployed)
        state && { "number" => number, "status" => status, "pr" => pr, "state" => state }
      end
    end

    # The fix that proves a `fixed` blocker has not landed — `[state, pr]` — or nil.
    #
    # ANY shipped fix clears it. A reopened issue accumulates fixes and `dev issues
    # fix` appends more after the fact, so "the newest fix is still open" is
    # routinely true of an issue whose code merged rounds ago — reading it as
    # unshipped would defer a dependent on a PR it never needed.
    #
    # Failing that, the fix is unshipped, and every way of being unshipped counts.
    # An OPEN fix is the common one. A fix CLOSED WITHOUT MERGING — rejected,
    # abandoned, or superseded by a PR opened under a url nobody recorded with
    # `dev issues fix` — used to answer nil, which every caller reads as "shipped,
    # dispatch is safe": the absence of unmerged evidence was standing in for
    # positive evidence of a merge, and a closed PR is neither (ISS-739). A fix
    # that MERGED and has not been released is the third (ISS-1097), and it is
    # the one this reads most often, since between a merge and the next release
    # every fix in a deployable repo is in that state.
    #
    # Which one is NAMED, when there are several: the open PR first — it is the
    # one that will actually ship, and the deferral note is only actionable if it
    # points at that — then the unreleased merge, then the LAST RECORDED closed
    # one. Last recorded rather than highest number because fixes span repos,
    # where PR numbers are not comparable, and the recorded order is the only
    # chronology available without a second API field.
    #
    # UNKNOWNS still return nil, which is the deliberate FAIL-OPEN policy: `gh`
    # unreachable, a fix that is a document, a state this file does not
    # recognise, a release state that could not be read. One unknown among
    # several is enough — the fix that shipped might be the one that could not be
    # read.
    def unlanded_fix(number, use_localhost:, deployed:)
      blocker = begin
        Agent::Api.issue(number, use_localhost: use_localhost)
      rescue StandardError
        nil
      end
      return nil if blocker.nil?

      urls = fix_pr_urls(blocker)
      return nil if urls.empty?

      states = urls.map { |url| fix_state(url, deployed: deployed) }
      return nil if states.any? { |state, _| state == :shipped }
      return nil if states.any? { |state, _| state == :unknown }

      states.find { |state, _| state == :open } ||
        states.find { |state, _| state == :unreleased } ||
        states.reverse.find { |state, _| state == :closed }
    end

    # The PR urls recorded as fixes on an issue. A fix that is a document (a design
    # doc, a plan) contributes nothing: there is no merge to wait for.
    def fix_pr_urls(issue)
      Array(issue["fixes"]).filter_map { |fix| fix["url"] if fix["url"].to_s.match?(FIX_PR_URL) }
    end

    # ---- the inverse question, asked of an issue ALREADY deferred (ISS-922) ----

    # Positive evidence that nothing this issue is blocked by is still waiting to
    # land. Agent::DependencyWake lifts a deferral on it, hours ahead of the
    # daily expiry that used to be the only way back.
    #
    # DELIBERATELY NOT `unshipped(...).empty?`, and the difference is the whole
    # safety argument. `unshipped` answers `[]` for every UNKNOWN, because the
    # dispatch gate FAILS OPEN: not knowing must never stall the queue. Inverted
    # into a wake signal that same `[]` says the opposite of what it means — one
    # rate-limited `gh` would unsnooze every deferred issue in the fleet at once,
    # and the claim behind each would re-defer it the moment `gh` answered again,
    # walking it toward the seven-attempt escalation for nothing.
    #
    # So this asks for the MERGE, and every unknown answers false: the deferral
    # stands and the daily expiry still applies, which is the fail-open policy
    # pointing the same way it always did — an unreadable GitHub changes nothing
    # about an issue that is already parked. Failing to wake early costs at most
    # a day, and the ISS-649 gate re-runs at claim time either way.
    #
    # An issue with NO blockers is cleared, vacuously and correctly: that is what
    # a human dropping the edge with `dev issues block --remove` leaves behind,
    # and it is exactly the state the escalation note asks them to produce.
    def cleared?(issue, use_localhost:, deployed: release_oracle)
      blockers(issue).all? { |ref| blocker_landed?(ref, use_localhost: use_localhost, deployed: deployed) }
    end

    # One blocker: is its code demonstrably on main AND in its repo's release?
    def blocker_landed?(ref, use_localhost:, deployed: release_oracle)
      status = ref["status"]
      # Live work by the tracker's own reckoning — there is nothing merged to
      # find, whatever GitHub says.
      return false unless SHIPPED_STATUSES.include?(status)
      # Nobody is ever going to ship it, so there is no merge to wait for and the
      # dependent is on its own. Positive by the same reading `unshipped` gives
      # it, and the one place this agrees with the tracker's status alone.
      return true if status == ABANDONED_STATUS

      blocker = begin
        Agent::Api.issue(ref["number"], use_localhost: use_localhost)
      rescue StandardError
        nil
      end
      return false if blocker.nil?

      # ANY shipped fix, mirroring `unlanded_fix`: a reopened issue accumulates
      # fixes, so "the newest one is still open" is routinely true of an issue
      # whose code merged rounds ago. An unreadable url contributes nothing here
      # rather than poisoning the answer — it is one absent piece of evidence,
      # and a fix found shipped elsewhere in the list is still shipped.
      #
      # No PR fix recorded at all — a fix that is a design document, or a `fixed`
      # with nothing attached — is NOT evidence: there is no merge to observe.
      # The claim-time gate dispatches on that case and this declines to wake on
      # it, which costs a day at most and only for an issue held by some OTHER
      # blocker, since a document-fixed blocker never causes a deferral itself.
      fix_pr_urls(blocker).any? { |url| fix_state(url, deployed: deployed).first == :shipped }
    end

    # How many CONSECUTIVE dependency deferrals a timeline records — the number
    # Agent::Tick's seven-attempt escalation counts, plus one for the deferral it
    # is about to write.
    #
    # CONSECUTIVE, not total, and that is the second half of ISS-922. The
    # escalation exists for a PR that is STUCK: "a week of daily checks has not
    # cleared it, so this needs a human rather than another day". An issue that
    # was blocked, cleared, dispatched, and later blocked again on an entirely
    # different PR is not that — but a running total counts it as though it were,
    # and a wake/re-defer round trip (which the sweep makes cheap enough to
    # happen) would push issues into `needs_input` on somebody else's history.
    #
    # Reading a wake as the reset point is what makes it consecutive, and it is
    # the only reset available: comments cannot be deleted, so there is nothing
    # to un-count.
    #
    # ORDER-SENSITIVE — oldest first, which is what `Agent::Api.issue_comments`
    # returns (`GET /issues/:number/comments`, offset paging from 0). A reversed
    # list would put the reset at the wrong end and count the deferrals BEFORE
    # the last wake instead of after it.
    def defer_attempts(comments)
      bodies = Array(comments).map { |c| c["body"].to_s }
      last_wake = bodies.rindex { |body| WAKE_MARKERS.any? { |marker| body.include?(marker) } }
      since = last_wake.nil? ? bodies : bodies[(last_wake + 1)..]
      since.count { |body| body.include?(DEFER_MARKER) }
    end

    # One line per blocker for the timeline note, naming what is actually being
    # waited on — the PR when there is one, the status when the blocker has not
    # got that far.
    def describe(unshipped)
      unshipped.map do |b|
        reason = pr_reason(b)
        next "ISS-#{b['number']} is still `#{b['status']}`" if reason.nil?

        "ISS-#{b['number']} is `#{b['status']}`, but #{reason}"
      end
    end

    # The PR half of one of those sentences, or nil when the blocker has no PR to
    # name — which is the blocker that never reached a shipped status, and whose
    # own status is the whole reason.
    #
    # Split out of `describe` because there are two readers now and only one of
    # them wants the "ISS-N is `fixed`" half (ISS-1085). The dispatcher writes
    # whole sentences into a timeline comment; `dev issues show` prints the
    # blocker's number, status and title on its own line and then this clause
    # underneath it. One source for the wording, so the note a session reads on
    # the timeline and the line a human reads before claiming cannot drift into
    # two different accounts of the same PR.
    #
    # A clause per state, because they want different things from whoever reads
    # it. An OPEN PR resolves itself: it merges, and the next attempt of this gate
    # passes. A CLOSED-unmerged one never will — either the real fix went in under
    # a url nobody recorded (`dev issues fix`) or the blocker was never actually
    # fixed — so that deferral loop can only end with a human, and "has not
    # merged" would hide it behind wording that reads as "not yet". An UNRELEASED
    # one waits on a DEPLOY rather than on a review, so it names the repo to
    # release; calling it unmerged would be flatly false about a commit sitting on
    # main, which is the confusion ISS-1097 was filed about.
    #
    # Driven off the recorded state rather than re-derived from the PR, because
    # the PR in the unreleased case IS merged — `merged?` can no longer stand in
    # for "landed".
    def pr_reason(entry)
      pr = entry["pr"]
      return nil if pr.nil?

      case entry["state"]
      when :closed
        "its fix #{pr['url']} was CLOSED WITHOUT MERGING — nothing shipped, and no open PR will ship it"
      when :unreleased
        "its fix #{pr['url']} merged and has NOT been released — that commit is not in the newest " \
          "`#{pr['url'][FIX_PR_URL, 1]}` release, so the code is on `origin/main` and not in production " \
          "where a session would have to test against it"
      else
        "its fix #{pr['url']} has not merged"
      end
    end
  end
end

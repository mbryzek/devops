require 'agent/api'
require 'agent/github'

# Has the code an issue is BLOCKED ON actually landed on main?
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
# FAIL OPEN, everywhere. `gh` missing, a rate limit, an unreadable blocker, a
# fix that is a document rather than a PR — every unknown dispatches. A
# dependency check that stalls the whole queue whenever GitHub is unreachable is
# a worse failure than the one it exists to prevent, and it would be silent.
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

    FIX_PR_URL = %r{\Ahttps://github\.com/[^/]+/[^/]+/pull/\d+}

    # How a merge-driven wake is recognised on the timeline (ISS-923), and the
    # counterpart to Agent::Tick::DEPENDENCY_DEFER_MARKER. The attempt count that
    # walks a stuck issue to `needs_input` is kept as a count of defer markers, so
    # a wake has to be visible in the same place: deferrals that happened BEFORE
    # this line are not evidence of a PR nobody will merge, because the PR they
    # named merged.
    WAKE_MARKER = "Woken by the merge lane".freeze

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

    # Every blocker whose code is NOT on main yet, each with the evidence: the
    # blocker's status, and the open PR that contradicts it when there is one.
    # Empty — the overwhelmingly common case, since most issues have no blockers
    # at all — means dispatch.
    def unshipped(issue, use_localhost:)
      blockers(issue).filter_map do |ref|
        number = ref["number"]
        status = ref["status"]
        # Live work by the tracker's own rule. The server passes these over when it
        # leases, so reaching here means something raced; agreeing with the server
        # costs one branch and cannot false-positive.
        next { "number" => number, "status" => status, "pr" => nil } unless SHIPPED_STATUSES.include?(status)
        next nil if status == ABANDONED_STATUS

        pr = unmerged_fix_pr(number, use_localhost: use_localhost)
        pr && { "number" => number, "status" => status, "pr" => pr }
      end
    end

    # The PR that proves a `fixed` blocker has not landed, or nil.
    #
    # ANY merged fix clears it. A reopened issue accumulates fixes and `dev issues
    # fix` appends more after the fact, so "the newest fix is still open" is
    # routinely true of an issue whose code merged rounds ago — reading it as
    # unshipped would defer a dependent on a PR it never needed.
    #
    # Failing that, the fix is unshipped, and BOTH ways of being unshipped count
    # (ISS-739). An OPEN fix is the common one. The other is a fix CLOSED WITHOUT
    # MERGING — rejected, abandoned, or superseded by a PR opened under a url
    # nobody recorded with `dev issues fix`. This used to answer nil there, which
    # every caller reads as "shipped, dispatch is safe": the absence of unmerged
    # evidence was standing in for positive evidence of a merge, and a closed
    # PR is neither. The dependent then dispatched against code that never landed
    # on main, which is exactly what ISS-649 exists to prevent. Note this is not
    # the deliberate FAIL-OPEN policy — that covers UNKNOWNS (`gh` unreachable,
    # a fix that is a document, a state this file does not recognise), and all of
    # those still return nil below. Here the answer is known and verifiable.
    #
    # Among several closed fixes it is the LAST RECORDED one, not the highest PR
    # number: fixes can span repos, where numbers are not comparable, and the
    # recorded order is the only chronology available without a second API field.
    def unmerged_fix_pr(number, use_localhost:)
      blocker = read(number, use_localhost: use_localhost)
      return nil if blocker.nil?

      urls = fix_pr_urls(blocker)
      return nil if urls.empty?

      prs = urls.map { |url| Agent::Github.pr_by_url(url) }
      return nil if prs.any?(&:nil?)
      return nil if prs.any? { |pr| Agent::Github.merged?(pr) }

      prs.find { |pr| Agent::Github.open?(pr) } || prs.reverse.find { |pr| Agent::Github.closed?(pr) }
    end

    # The PR urls recorded as fixes on an issue. A fix that is a document (a design
    # doc, a plan) contributes nothing: there is no merge to wait for.
    def fix_pr_urls(issue)
      Array(issue["fixes"]).filter_map { |fix| fix["url"] if fix["url"].to_s.match?(FIX_PR_URL) }
    end

    # One line per blocker for the timeline note, naming what is actually being
    # waited on — the PR when there is one, the status when the blocker has not
    # got that far.
    #
    # A CLOSED fix gets its own sentence, because the two cases want different
    # things from whoever reads the note. An open PR resolves itself: it merges,
    # and the next attempt of this gate passes. A closed-unmerged one never will
    # — either the real fix went in under a url nobody recorded (`dev issues
    # fix`) or the blocker was never actually fixed — so the deferral loop can
    # only end with a human, and saying "has not merged" would hide that behind
    # wording that reads as "not yet".
    def describe(unshipped)
      unshipped.map do |b|
        pr = b["pr"]
        if pr && Agent::Github.closed?(pr)
          "ISS-#{b['number']} is `#{b['status']}`, but its fix #{pr['url']} was CLOSED WITHOUT MERGING — " \
            "nothing shipped, and no open PR will ship it"
        elsif pr
          "ISS-#{b['number']} is `#{b['status']}`, but its fix #{pr['url']} has not merged"
        else
          "ISS-#{b['number']} is still `#{b['status']}`"
        end
      end
    end

    # ---- the other direction: the deferrals a merge just released (ISS-923) ----
    #
    # The gate above puts a blocked issue down for a day at a time, and the day is
    # a guess about a human: it re-asks GitHub tomorrow because there is nothing to
    # ask sooner. But the merge lane (Agent::MergeLane) is the ONLY merger in this
    # fleet, so at the moment it merges a PR the guess is no longer needed — the
    # wait it was covering has just ended, exactly then, and up to 24 hours of the
    # deferral left to run is pure latency. ISS-858 sat deferred with platform#2190
    # already merged until somebody woke it by hand.
    #
    # So this is called from the merge, and it asks of the same records the gate
    # reads: which deferred issues have a blocker that records THIS url as a fix,
    # and of those, which have every OTHER blocker shipped as well. An issue can be
    # waiting on several things, and waking it on the first merge would hand a
    # session code it still cannot branch from.
    #
    # MERGED IS THE SIGNAL, not deployed. The gate reads merged-to-origin/main
    # because all a dependent session needs is code on `main` to branch from;
    # waiting on a deploy would add hours and answer no question anybody asked.
    #
    # FAIL OPEN, in the OPPOSITE DIRECTION from the gate, which is why this asks
    # `shipped?` rather than reusing `unshipped`. The gate's unknowns dispatch,
    # because refusing to dispatch on an unreachable GitHub would stall the whole
    # queue; here the unknowns must LEAVE THE SNOOZE ALONE, because the deferral is
    # already a working fallback that expires on its own. Both err toward the daily
    # loop. Read through `unshipped`, a `gh` outage would wake every deferral this
    # merge touched — each one burning a lease to re-defer itself — for no gain
    # over waiting for the expiry.
    #
    # Nothing here can dispatch anything early in any case: the claim re-runs the
    # gate from scratch and simply defers again, so the worst a wrong wake costs is
    # one lease.
    def wake_dependents(pr_url, use_localhost:)
      url = normalize(pr_url)
      return [] if url.nil?

      fixes_of = {}
      deferred(use_localhost: use_localhost).filter_map do |issue|
        next nil unless released_by?(issue, url, fixes_of, use_localhost: use_localhost)

        wake(issue["number"], url, use_localhost: use_localhost)
      end
    rescue StandardError
      []
    end

    # Every deferred issue, read in full. The list rows are not enough: `links` is
    # the whole question here and only the single-issue read is guaranteed to carry
    # it, so this pays one call per deferred issue — a handful, once per merge.
    def deferred(use_localhost:)
      Agent::Api.snoozed_issues(use_localhost: use_localhost).filter_map do |row|
        number = row["number"]
        number && read(number, use_localhost: use_localhost)
      end
    end

    # Did THIS merge release this deferral — and did it release it completely?
    #
    # Two questions, in this order because the first is cheap and almost always
    # answers no: most deferred issues have nothing to do with the PR in hand, and
    # some are not deferred on a dependency at all. `fixes_of` memoizes the blocker
    # reads across the walk, because several dependents of one blocker is the
    # normal shape of a fan-out.
    def released_by?(issue, url, fixes_of, use_localhost:)
      refs = blockers(issue)
      return false unless refs.any? { |ref| fixes(ref, fixes_of, use_localhost: use_localhost).include?(url) }

      refs.all? { |ref| shipped?(ref, fixes(ref, fixes_of, use_localhost: use_localhost), url) }
    end

    # One blocker's fix urls, as the PRs they name, read once per blocker per walk.
    def fixes(ref, fixes_of, use_localhost:)
      number = ref["number"]
      fixes_of[number] ||= fix_pr_urls(read(number, use_localhost: use_localhost) || {})
                           .filter_map { |u| normalize(u) }
    end

    # POSITIVE evidence that one blocker's code is on main: abandoned, or a fix
    # that is the PR the lane just merged, or a fix GitHub reports as merged.
    #
    # The just-merged url counts WITHOUT asking `gh`, and it is the only fact this
    # whole feature adds over the daily loop: the lane merged it a moment ago, so
    # there is no read that could be more authoritative — and none that could be
    # more current either, with GitHub's own API lagging its merges by seconds.
    #
    # Everything else is `false`: a blocker with no PR fix (a document), a `gh`
    # that answered nothing, a state this file does not recognise. Those are
    # unknowns, and an unknown does not clear somebody's snooze.
    def shipped?(ref, fix_urls, merged_url)
      return true if ref["status"] == ABANDONED_STATUS
      return false unless SHIPPED_STATUSES.include?(ref["status"])

      fix_urls.any? do |url|
        next true if url == merged_url

        pr = Agent::Github.pr_by_url(url)
        pr && Agent::Github.merged?(pr)
      end
    end

    # Clear the snooze, then say why on the timeline; the issue's number when the
    # snooze actually cleared, nil otherwise.
    #
    # THE WAKE FIRST, THE NOTE SECOND, because the two half-failures are not
    # equally bad. A note without a wake would reset the attempt count (see
    # WAKE_MARKER) on an issue still sitting out of the queue — which is the silent
    # aging DEPENDENCY_DEFER_LIMIT exists to prevent. A wake without a note only
    # costs the issue its restarted count, so a still-blocked one reaches a human
    # sooner. Aging quietly is the failure worth refusing.
    def wake(number, url, use_localhost:)
      return nil if quietly { Agent::Api.wake(number, use_localhost: use_localhost) }.nil?

      quietly do
        Agent::Api.comment(number, "#{WAKE_MARKER} — #{url} merged, and every issue this one is blocked by " \
                                   "now has its code on `origin/main`. The snooze is cleared and this is back " \
                                   "in the queue; the dependency check is rerun against GitHub when it is claimed.",
                           use_localhost: use_localhost)
      end
      number
    end

    def read(number, use_localhost:)
      Agent::Api.issue(number, use_localhost: use_localhost)
    rescue StandardError
      nil
    end

    def quietly
      yield
    rescue StandardError
      nil
    end

    # A fix url can be recorded with a trailing path or query (`/files`, a review
    # anchor) and the lane hands over the PR's canonical url, so the two are
    # compared as the PR they name rather than as strings. nil for a fix that is a
    # document: there is no merge to match it against.
    def normalize(url)
      url.to_s[FIX_PR_URL]
    end
  end
end

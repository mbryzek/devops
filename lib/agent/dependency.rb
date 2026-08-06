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

    # The open PR that proves a `fixed` blocker has not landed, or nil.
    #
    # ANY merged fix clears it. A reopened issue accumulates fixes and `dev issues
    # fix` appends more after the fact, so "the newest fix is still open" is
    # routinely true of an issue whose code merged rounds ago — reading it as
    # unshipped would defer a dependent on a PR it never needed.
    def unmerged_fix_pr(number, use_localhost:)
      blocker = begin
        Agent::Api.issue(number, use_localhost: use_localhost)
      rescue StandardError
        nil
      end
      return nil if blocker.nil?

      urls = fix_pr_urls(blocker)
      return nil if urls.empty?

      prs = urls.map { |url| Agent::Github.pr_by_url(url) }
      return nil if prs.any?(&:nil?)
      return nil if prs.any? { |pr| Agent::Github.merged?(pr) }

      prs.find { |pr| Agent::Github.open?(pr) }
    end

    # The PR urls recorded as fixes on an issue. A fix that is a document (a design
    # doc, a plan) contributes nothing: there is no merge to wait for.
    def fix_pr_urls(issue)
      Array(issue["fixes"]).filter_map { |fix| fix["url"] if fix["url"].to_s.match?(FIX_PR_URL) }
    end

    # One line per blocker for the timeline note, naming what is actually being
    # waited on — the PR when there is one, the status when the blocker has not
    # got that far.
    def describe(unshipped)
      unshipped.map do |b|
        pr = b["pr"]
        if pr
          "ISS-#{b['number']} is `#{b['status']}`, but its fix #{pr['url']} has not merged"
        else
          "ISS-#{b['number']} is still `#{b['status']}`"
        end
      end
    end
  end
end

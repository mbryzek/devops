require 'set'

# Cross-repo pull-request groups, and the order their members must merge in
# (ISS-758).
#
# A change that spans repos lands as several PRs that must merge in a particular
# order, and nothing enforced that order: it lived in one person's head. ISS-698
# is the case this was written from — `platform#2133`, `playbook-admin#815`,
# `playbook-app#460` and `platform-postgresql#514`, one logical change, where
# merging a consumer ahead of its producer ships a swallowed 404 that renders as
# "No data" (playbook-admin #760, the incident the `costly` reversibility class
# exists for).
#
# ## The join key is the branch name, and it already exists
#
# Sibling PRs share a `headRefName` VERBATIM across repos, because the executor
# assigns one branch per unit of work and `agent/instructions.md` §4 forbids
# renaming it. So discovering a cross-repo change needs no new metadata and no
# new registry to drift: group open PRs by head branch.
#
# The grouping is an EXACT match on the branch name, not a prefix match on the
# `i<n>_<suffix>` stem, and that is deliberate. `<branch>_<suffix>` siblings are
# the ISS-657 convention for a run that produced several INDEPENDENT PRs — by
# construction they have no ordering between them, so folding them into one
# group would invent a dependency the contract explicitly says is not there.
# Drift in the other direction (a repo whose branch grew a suffix its siblings
# do not have — `i735_tej_404` in devops) is reported by `suspected_drift`
# rather than silently joined, because guessing wrong here would order two
# unrelated PRs against each other.
#
# ## Ordering is inferred from repo role, and OVERRIDDEN by a declared edge
#
# Role ordering (schema, then libraries, then the spec owner, then consumer
# regens) is right for every group measured so far, and it is only ever an
# inference. A PR body may declare the real edge:
#
#     depends-on: platform#2133
#     depends-on: platform#2133 merged
#
# The first — the default — means "that PR must have DEPLOYED". The second
# relaxes it to "merged is enough". Deploy, not merge, is the default because it
# is the condition a single-PR check cannot see and the one that actually broke
# production. A group with any declared edge is ordered ENTIRELY by its declared
# edges; inference does not top them up, or a body could only ever add
# constraints and never correct a wrong one.
#
# Nothing here reads the `c<n>` in a branch name as an ordinal. It is creation
# order, not merge order, and a lane that treated it as a dependency would be
# right most of the time and silently wrong when a child is added late — the
# failure mode that costs a day because the convention appeared to work.
#
# ## Everything in this file is PURE
#
# GitHub and the deploy probe arrive as lambdas. That keeps the decision — which
# PR may merge and why — testable without a network, and it is the same split
# `Agent::Github` draws between reading and deciding.
module Prs
  module Group
    module_function

    # What a repo contributes to a cross-repo change, and therefore where it
    # sits in the merge order. Lower merges first.
    #
    # `self_deploying` is last and is never really ordered: a group containing
    # one is a human decision outright (see `human_only?`). It is a property of
    # the repo's DEPLOY PATH, not of its diff — every runner fast-forwards its
    # ~/code/devops checkout at the top of every tick, so merging there is
    # deploying, fleet-wide, within 30 seconds.
    ROLE_ORDER = { schema: 0, library: 1, producer: 2, consumer: 3, self_deploying: 4 }.freeze

    # The repo whose merge IS its deploy. One entry today; a list rather than an
    # `== "devops"` so the next repo to gain a self-update is classified rather
    # than assumed.
    SELF_DEPLOYING_REPOS = %w[devops].freeze

    DB_REPO_SUFFIX = "-postgresql".freeze
    LIB_REPO_PREFIX = "lib-".freeze

    # `scala_repos` is the set that owns apibuilder specs and DAO definitions —
    # platform, acumen. Passed in rather than hardcoded because the registry is
    # the source of truth for which apps those are, and this file may not reach
    # for it.
    def role(repo, scala_repos: [])
      name = bare_repo(repo)
      return :self_deploying if SELF_DEPLOYING_REPOS.include?(name)
      return :schema if name.end_with?(DB_REPO_SUFFIX)
      return :library if name.start_with?(LIB_REPO_PREFIX)
      return :producer if scala_repos.map { |r| bare_repo(r) }.include?(name)
      :consumer
    end

    def role_order(role) = ROLE_ORDER.fetch(role, ROLE_ORDER[:consumer])

    # `mbryzek/platform` and `platform` are the same repo. Both spellings reach
    # here — `gh pr list --repo` takes the first, a `depends-on:` line is written
    # with the second.
    def bare_repo(repo) = repo.to_s.split("/").last.to_s

    def key(repo, number) = "#{bare_repo(repo)}##{number}"

    def pr_key(pr) = key(pr["repository"] || pr["repo"], pr["number"])

    # ---- declared edges ----

    # `depends-on: <repo>#<n>` in a PR body, optionally followed by the word
    # `merged` to relax the default deploy requirement. Case-insensitive, one per
    # line, anywhere in the body — a session writes this into the description it
    # is already writing, and nothing else has to be kept in step.
    #
    # Deliberately NOT matched inside a fenced code block or a quote: this file
    # is pure and has no parser, and the cost of a false positive is a PR held
    # for review rather than merged early. Held is the safe direction.
    DEPENDS_ON = /^[ \t>]*depends-on:[ \t]*([A-Za-z0-9._-]+)#(\d+)[ \t]*(merged|deployed)?[ \t]*$/i

    Edge = Struct.new(:repo, :number, :requires_deploy, keyword_init: true) do
      def key = Prs::Group.key(repo, number)
    end

    def declared_edges(body)
      body.to_s.scan(DEPENDS_ON).map do |repo, number, requirement|
        Edge.new(repo: repo, number: number.to_i,
                 requires_deploy: !requirement.to_s.casecmp?("merged"))
      end
    end

    # ---- groups ----

    Member = Struct.new(:pr, :role, :edges, :verdict, :reason, keyword_init: true) do
      def repo = Prs::Group.bare_repo(pr["repository"] || pr["repo"])
      def number = pr["number"]
      def key = Prs::Group.key(repo, number)
      def state = pr["state"].to_s.upcase
      def draft? = state == "OPEN" && !!pr["isDraft"]
      def open? = state == "OPEN"
      def merged? = state == "MERGED"
      def merge_sha = pr.dig("mergeCommit", "oid") || pr["mergeCommitOid"]
      def to_s = key
    end

    Result = Struct.new(:branch, :members, :human_only, :suspected_drift, keyword_init: true) do
      def cross_repo? = members.map(&:repo).uniq.length > 1
      def open_members = members.select(&:open?)
      def blocked = open_members.reject { |m| m.verdict == :eligible }
    end

    # Group PRs by head branch, order each group, and give every member a
    # verdict.
    #
    # `lookup` resolves a `depends-on:` edge that names a PR outside the group
    # (or outside the enumerated set) to its GitHub JSON, or nil for "cannot
    # tell". `deployed` answers whether a merge commit is contained in what the
    # repo is currently running: true, false, or nil for unknown. Both default to
    # "unknown", and unknown always HOLDS — a group this code cannot reason about
    # is a group a human looks at.
    def build(prs, scala_repos: [], lookup: ->(_repo, _number) { nil }, deployed: ->(_repo, _sha) { nil })
      by_branch = prs.compact.group_by { |pr| pr["headRefName"].to_s }.reject { |b, _| b.empty? }
      branches = by_branch.keys
      by_branch.map do |branch, group_prs|
        members = group_prs
                  .uniq { |pr| pr_key(pr) }
                  .map { |pr| Member.new(pr: pr, role: role(pr["repository"] || pr["repo"], scala_repos: scala_repos),
                                         edges: declared_edges(pr["body"])) }
                  .sort_by { |m| [role_order(m.role), m.repo, m.number.to_i] }
        result = Result.new(branch: branch, members: members,
                            human_only: members.any? { |m| m.role == :self_deploying },
                            suspected_drift: suspected_drift(branch, branches))
        assign_verdicts(result, lookup: lookup, deployed: deployed)
        result
      end.sort_by { |g| g.branch }
    end

    # A branch that is another enumerated branch plus a `_<suffix>` — the
    # `i735_tej_404` shape. Reported, never joined: it is either the ISS-657
    # sibling convention (independent PRs, correctly separate) or the drift
    # ISS-758 wants to stop, and only a human can tell which.
    def suspected_drift(branch, branches)
      branches.select { |other| other != branch && branch.start_with?("#{other}_") }
    end

    # ---- ordering and verdicts ----

    # Who each member waits on: every declared edge, plus every edge inferred
    # from role order that a declared edge does not CONTRADICT.
    #
    # Neither half alone is right. Declared-only would mean one `depends-on:`
    # line in one body silently drops the schema ordering for the whole group —
    # a body that says less would constrain less, which is the wrong direction
    # for a safety check. Inferred-only would mean a body can add constraints but
    # never correct a wrong one, and the reason declared edges exist at all is
    # that role order is an inference.
    #
    # So an inferred A→B is dropped exactly when B declares A — the author has
    # stated the dependency runs the other way, and keeping both would be a cycle
    # this code invented.
    def dependencies(result)
      declared = result.members.to_h { |m| [m.key, m.edges] }
      reversed = Set.new(result.members.flat_map { |m| m.edges.map { |e| [e.key, m.key] } })

      result.members.to_h do |m|
        inferred = result.members
                         .select { |o| role_order(o.role) < role_order(m.role) }
                         .reject { |o| reversed.include?([m.key, o.key]) }
                         .map { |o| Edge.new(repo: o.repo, number: o.number, requires_deploy: true) }
        # Declared first, so its deploy requirement survives the dedupe: an
        # inferred edge always demands a deploy, and `depends-on: x merged` is
        # the author saying it does not.
        [m.key, (declared.fetch(m.key, []) + inferred).uniq(&:key)]
      end
    end

    # Members caught in a declared-edge cycle. A cycle is a body somebody wrote
    # wrong; it cannot be resolved by ordering, so every member in one holds.
    def cyclic_keys(deps)
      done = Set.new
      cyclic = Set.new
      walk = lambda do |k, stack|
        return unless deps.key?(k)
        # `stack` is the path that reached k. Seeing k on it closes a cycle, and
        # everything from that point on is in it.
        if stack.include?(k)
          cyclic.merge(stack[stack.index(k)..])
          return
        end
        return if done.include?(k)
        deps[k].each { |e| walk.call(e.key, stack + [k]) }
        done << k
      end
      deps.each_key { |k| walk.call(k, []) }
      cyclic
    end

    def assign_verdicts(result, lookup:, deployed:)
      deps = dependencies(result)
      cyclic = cyclic_keys(deps)
      by_key = result.members.to_h { |m| [m.key, m] }

      result.members.each do |member|
        verdict, reason = member_verdict(member, deps.fetch(member.key, []), by_key,
                                         human_only: result.human_only, cyclic: cyclic,
                                         lookup: lookup, deployed: deployed)
        member.verdict = verdict
        member.reason = reason
      end
    end

    def member_verdict(member, edges, by_key, human_only:, cyclic:, lookup:, deployed:)
      return [:merged, nil] if member.merged?
      return [:closed, nil] unless member.open?
      return [:human, "devops is in this group; merging there deploys the fleet"] if human_only
      return [:draft, nil] if member.draft?
      return [:cycle, "declared dependencies form a cycle"] if cyclic.include?(member.key)

      edges.each do |edge|
        verdict, reason = edge_verdict(edge, by_key, lookup: lookup, deployed: deployed)
        return [verdict, reason] if verdict
      end
      [:eligible, nil]
    end

    # nil when the edge is satisfied; otherwise the verdict that holds the member.
    def edge_verdict(edge, by_key, lookup:, deployed:)
      dep = by_key[edge.key] || wrap(edge, lookup.call(edge.repo, edge.number))
      return [:unknown_dependency, "cannot resolve #{edge.key}"] if dep.nil?
      return [:waits_on_merge, "#{edge.key} has not merged"] unless dep.merged?
      return nil unless edge.requires_deploy

      sha = dep.merge_sha
      return [:unknown_deploy, "#{edge.key} merged, but its merge commit is unknown"] if sha.to_s.empty?

      case deployed.call(dep.repo, sha)
      when true  then nil
      when false then [:waits_on_deploy, "#{edge.key} merged but has not deployed"]
      else [:unknown_deploy, "cannot tell whether #{edge.key} has deployed"]
      end
    end

    def wrap(edge, pr)
      return nil if pr.nil?
      Member.new(pr: pr.merge("repository" => pr["repository"] || edge.repo), role: :consumer, edges: [])
    end

    # One line per member, for the terminal. The verdict is the column a reader
    # is actually looking for, so it comes last and carries its reason with it.
    VERDICT_LABELS = {
      eligible: "eligible",
      merged: "merged",
      closed: "closed",
      draft: "draft",
      human: "HOLD (human)",
      cycle: "HOLD",
      waits_on_merge: "HOLD",
      waits_on_deploy: "HOLD",
      unknown_dependency: "HOLD",
      unknown_deploy: "HOLD",
    }.freeze

    def label(member)
      base = VERDICT_LABELS.fetch(member.verdict, member.verdict.to_s)
      member.reason ? "#{base} - #{member.reason}" : base
    end
  end
end

require 'time'
require 'agent/api'

# The work a release leaves behind, filed as issues the fleet picks up — not run
# inline while the person who typed `dev deploy` watches it.
#
# WHY THIS EXISTS (ISS-816, ISS-817, epic ISS-814).
#
# Four things used to run at the end of every release, AFTER the rollout the
# release script already waited for: `api publish`, `dev changelog --app X`, and
# the two global reconcilers. The app is live before any of them starts, so all
# four are bookkeeping — and all four are slow. Acumen's post-release ran 23
# minutes before a Ctrl-C on 2026-08-07 with nothing about the deploy needing a
# human (ISS-809).
#
# One of them gets BETTER by moving, not merely faster. `api publish` does two
# things: it uploads the specs (moving registry `latest` to what is actually
# released) and it downloads the generated code back into the checkout it ran
# in. On a laptop that second half is drift nobody commits — `~/code/acumen` sat
# on `main` with two modified `generated/` files after every release, which was
# the normal outcome and not an accident. A fleet worker has its own clone
# (Agent::Workspace), so the same run ends in a PR (ISS-817).
#
# FILING IS DISPATCHING. An `open` issue is picked up by the fleet on its own,
# so there is no second queue here and nothing to poll: this files, prints what
# it filed, and the release is over.
#
# THE SHAPE, and the reasons it is not the obvious one:
#
#   - ONE epic per `dev deploy` invocation, not per app. A deploy releases at
#     concurrency 10; an epic per app would mint five containers for one deploy
#     and bury the queue `dev issues claim` reads under bookkeeping.
#   - The two reconcilers are ONE child, not one per app and not one each. Both
#     are deliberately global — they evaluate everything outstanding — which is
#     exactly why running them per app was redundant (ISS-810).
#   - The publish is one child PER APP, because each one is a different clone
#     with a different generated diff and therefore a different PR.
#
# THE CATEGORY IS `infrastructure`, and that is why this files through
# `Agent::Api` rather than shelling out to `dev issues create`. The CLI refuses
# that category on purpose (ISS_MANUAL_CATEGORIES) — it is for producer-filed
# chores whose fix may name no pull request, advanced straight to `deployed`
# with the usual 7-day auto-verify. That is exactly this work, and a deploy is
# exactly a producer.
#
# WHAT IS NOT SOFTENED. `api publish` was deliberately not best-effort inline: a
# deployed API whose specs did not publish is the drift the hermetic design
# exists to prevent. Moving it does not relax that, it RESTATES it — the issue
# must not be quietly dismissed, and a filing failure fails the deploy loudly
# with the commands to run by hand (`manual_commands`), because an unfiled
# publish is silent exactly the way an unrun one was.
class PostDeployWork
  # Set by `dev deploy` on every release it spawns: "I file the post-deploy work
  # myself, once, for all of us — do not file your own." A standalone `release`
  # sees no such variable and files for the single app it released, because
  # there the release IS the whole deploy.
  DEFER_ENV = "DEVOPS_DEFER_POST_RELEASE".freeze

  # Producer-filed dev-infrastructure chores. See the class comment.
  CATEGORY = "infrastructure".freeze

  # Only these apps feed the changelog pipeline.
  CHANGELOG_TRACKED = %w[playbook-admin playbook-app playbook-www].freeze

  # The two global reconcilers, as [command, what it reconciles].
  RECONCILERS = [
    ["features", "feature-flag cleanup"],
    ["issues", "`fixed` -> `deployed` transitions"],
  ].freeze

  # What to tell an operator to run by hand when the filing failed BEFORE this
  # work could say what it owed. `manual_commands` is derived from `tasks`, and
  # `tasks` is exactly what fails in that case (it reads every released
  # checkout's `.api` config, which aborts on a broken one) — so the narration of
  # that failure cannot ask `tasks` what to print. Deliberately app-agnostic:
  # nothing is known about the released apps at that point beyond their names.
  MANUAL_COMMANDS_FALLBACK = [
    "api publish (in each released app)",
    "dev features reconcile --apply",
    "dev issues reconcile --apply",
  ].freeze

  # An app this deploy released, and the checkout it released from. The
  # directory is what answers "does this one own apibuilder specs" — `dev deploy`
  # knows it as `deploy_item_dir(name)`, a standalone release as `Dir.pwd`.
  App = Struct.new(:name, :dir, keyword_init: true)

  # One child issue: what the fleet is being asked to do, and the repositories
  # the executor clones before the session starts (empty for a chore that runs
  # from anywhere).
  Task = Struct.new(:title, :body, :repos, :commands, keyword_init: true)

  # What was filed, for the report the deploy prints. Numbers, not objects: the
  # only thing anyone does with them is read them and follow them.
  Filed = Struct.new(:epic, :children, keyword_init: true) do
    # children: [[number, title], ...]
    def report_lines
      ["ISS-#{epic} (epic)"] + children.map { |number, title| "  ISS-#{number} #{title}" }
    end
  end

  def self.deferred? = ENV[DEFER_ENV] == "1"

  # The environment a deploy adds to the releases it spawns. A hash so it merges
  # into the env `dev deploy` already passes (RELEASE_AUTO_TAG and friends).
  def self.defer_env = { DEFER_ENV => "1" }.freeze

  # `owns_specs` is a seam for the same reason `run` was on PostRelease: the
  # composition of this work is worth testing without a checkout on disk.
  def initialize(apps:, now: Time.now, api: Agent::Api, use_localhost: false,
                 owns_specs: ->(app) { PostRelease.owns_specs?(app.dir) })
    @apps = Array(apps)
    @now = now
    @api = api
    @use_localhost = use_localhost
    @owns_specs = owns_specs
  end

  def app_names = @apps.map(&:name)

  # Every child this deploy owes, in the order a human would want them done:
  # publishes first (the only one with a real clock on it — consumers regenerate
  # against `latest`), then the changelog, then the reconcilers.
  # A deploy that released no app owes nothing: a database, a library and a
  # devops pull ran no post-release at all, and none of them changes what
  # production is RUNNING — the only question either reconciler asks.
  def tasks
    return @tasks ||= [] if @apps.empty?

    @tasks ||= @apps.select { |app| @owns_specs.call(app) }.map { |app| publish_task(app) } +
               [changelog_task, reconcile_task].compact
  end

  def any? = tasks.any?

  # Files the epic and its children. Returns Filed, or nil when this deploy owes
  # nothing (a database, a library or a devops pull leaves no post-deploy work).
  #
  # NOT best-effort, and not rescued here: the caller decides how loud a filing
  # failure is, and both callers make it fail the release.
  def file!
    return nil if tasks.empty?

    epic = create(epic_form)
    children = tasks.map do |task|
      child = create(child_form(task, epic))
      [child, task.title]
    end
    Filed.new(epic: epic, children: children)
  end

  # What a human runs by hand if the filing failed. The whole point of the
  # not-best-effort severity: an unfiled publish is exactly as silent as an
  # unrun one, so the fallback has to be printed, not remembered.
  def manual_commands = tasks.flat_map(&:commands)

  private

  def create(form)
    @api.create_issue(form.merge(category: CATEGORY, claim_on_create: false),
                      use_localhost: @use_localhost).fetch("number")
  end

  def epic_form
    {
      type: "epic",
      title: "Post-deploy work for #{app_names.join(', ')}",
      body: epic_body,
    }
  end

  def child_form(task, epic)
    form = { parent_number: epic, title: task.title, body: task.body }
    form[:repositories] = task.repos unless task.repos.empty?
    form
  end

  def released_at = @now.utc.strftime("%Y-%m-%d %H:%M UTC")

  def epic_body
    <<~BODY
      `dev deploy` released #{app_names.join(', ')} at #{released_at} and filed this instead of
      running the post-deploy steps inline (ISS-814). Everything under here is bookkeeping the
      release used to do while somebody watched it: the app has been live since before this issue
      existed.

      Each child says exactly what to run. None of them needs a decision, and none of them may be
      dismissed for being small — a post-deploy step that silently never runs is the failure this
      epic exists to make visible, not to hide better.
    BODY
  end

  # --- the children ---

  # The publish, per app. This is the one that gets better by moving: the same
  # command that left uncommitted `generated/` churn on a laptop leaves a PR
  # when it runs in the fleet's own clone.
  def publish_task(app)
    Task.new(
      title: "Publish #{app.name} apibuilder specs and PR the generated churn",
      repos: [app.name],
      commands: ["cd ~/code/#{app.name} && api publish"],
      body: <<~BODY,
        #{app.name} released at #{released_at}. Publish its apibuilder specs.

        Registry `latest` means "the specs of the API actually running in production" — dev `api`
        runs are hermetic and never write the registry, so the release is the only thing that moves
        it. Until this runs, `latest` still describes the PREVIOUS release, and any consumer that
        regenerates in the meantime generates against stale specs. That window is the known cost of
        filing this instead of running it inline; keep it short. It cuts both ways once you are in
        it: publishing from `main` publishes the specs of every commit merged since the release, so
        the longer this sits the more of the registry describes code that is not deployed yet.
        Neither direction is worth a workaround — just run it.

        FROM `main`, in the `#{app.name}` checkout this session was given. `api publish` is the only
        path that writes the registry and it is guarded accordingly: it refuses to run from any
        branch but `main`, refuses a dirty working tree, and requires HEAD to be merged into
        origin/main. The executor put this checkout on your issue branch, so switch first:

            git checkout main && git pull --ff-only origin main

        Then run it through the ops close-out contract:

            dev agent run-op api-publish -- api publish

        `run-op` executes the command and files a record written from the COMMAND's own exit status
        and output, which is what closes this issue out. Do not close it by hand. `api publish`
        uploads 100+ apibuilder applications and waits on codegen, so start it detached
        (`nohup ... > /tmp/api-publish.log 2>&1 &`) and poll the log rather than letting your own
        tool-call timeout kill it half-run.

        `api publish` does TWO things: it uploads the specs, and it downloads the generated code
        back into the checkout it ran in. That second half is the reason this is a fleet job at all
        (ISS-817) — on a laptop the generated diff simply sat in `~/code/#{app.name}` uncommitted
        forever. So when the run finishes:

        - `git status`. If anything under `generated/` changed, move those changes onto your issue
          branch (`git checkout <the branch the executor gave you>` carries them across), commit,
          open a draft PR titled `ISS-<this issue number>: regenerate #{app.name} after publishing
          released specs`, and mark it ready.
        - If nothing changed, there is nothing to PR and the `run-op` record is the whole artifact.
          Do not manufacture a PR to look productive.

        A FAILED publish is not something to dismiss or work around. A deployed API whose specs did
        not publish is exactly the drift the hermetic design exists to prevent, and it was
        deliberately allowed to fail the release when this ran inline. A failed `run-op` returns
        this issue to the queue to be run again — that is the intended behaviour. If it cannot
        succeed at all, say why with `dev issues status <n> --status needs_input`.
      BODY
    )
  end

  # One child for every changelog-tracked app in this deploy, rather than one
  # each: they are independent one-line commands against the same pipeline, and
  # a deploy that mints an issue per app per step is the noise ISS-814 set out
  # to avoid.
  def changelog_task
    apps = app_names & CHANGELOG_TRACKED
    return nil if apps.empty?

    commands = apps.map { |name| "dev changelog --app #{name}" }
    Task.new(
      title: "Record the changelog for #{apps.join(', ')}",
      repos: [],
      commands: commands,
      body: <<~BODY,
        #{apps.join(', ')} released at #{released_at} and the tags exist, so the changelog can be
        captured. Run the whole pipeline (capture, then build) — the notes are served from the API,
        nothing is baked into a build, and there is no reason to defer the model step:

        #{apps.map { |name| "    dev agent run-op changelog-#{name} -- dev changelog --app #{name}" }.join("\n")}

        Each one goes through `dev agent run-op`, which executes the command and files a record
        written from the command's own exit status and output. That record is what closes this
        issue out — do not close it by hand, and do not skip a command you expect to be a no-op: a
        run that recorded nothing is indistinguishable from a session that did nothing, which is
        how a chore gets dismissed with the work never done.

        `run-op` exits with the command's own status, so `&&` between two of them stops at the
        first failure. This runs from anywhere; no checkout is needed.
      BODY
    )
  end

  # The two global reconcilers, as ONE child.
  #
  # Neither is scoped to the app that just released, deliberately: a feature
  # removal (or a fixed issue) usually waits on more than one app, so releasing
  # platform can be what clears one that was also waiting on playbook-app. That
  # global scope is exactly why a deploy owes ONE run of each rather than one
  # per app — five apps meant five unsynchronised `--apply` writers over the same
  # state, of which runs two through five could only re-evaluate what run one had
  # already applied (ISS-810).
  def reconcile_task
    commands = RECONCILERS.map { |command, _| "dev #{command} reconcile --apply" }
    Task.new(
      title: "Reconcile feature flags and issue statuses after #{app_names.join(', ')}",
      repos: [],
      commands: commands,
      body: <<~BODY,
        #{app_names.join(', ')} released at #{released_at}. Both reconcilers gate on "what is
        production running", and a release is the only event that can change that answer — which is
        why they hang off a deploy rather than a cron nobody would remember to install.

        #{RECONCILERS.map { |command, what| "- `dev #{command} reconcile --apply` — #{what}" }.join("\n")}

        Neither is scoped to an app: both evaluate everything outstanding, which is why one run
        covers a deploy of any size. Do not add `--app` to either.

            dev agent run-op features-reconcile -- dev features reconcile --apply && \\
              dev agent run-op issues-reconcile -- dev issues reconcile --apply

        `run-op` executes each command and files a record from the COMMAND's own exit status and
        output — including its counts, which both reconcilers print inside an ops run. That record
        is the close-out: do not set a status by hand. Run BOTH even if you expect them to move
        nothing; "reconciled 0" is a result, and an unrecorded run looks exactly like a session that
        did nothing.

        This runs from anywhere; no checkout is needed.
      BODY
    )
  end
end

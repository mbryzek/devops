require 'minitest/autorun'
require 'stringio'

# lib/ is the load root for the suite, exactly as lib/common.rb makes it the load
# root for every bin/ script. Every module under lib/ pulls in its siblings by
# name (`require 'agent/paths'`), so a test that requires ONE module directly —
# rather than loading the whole `dev` CLI — resolves those sibling requires only
# if lib/ is on $LOAD_PATH. Nothing else in a test process puts it there.
#
# The failure this removes is silent rather than red: the require blows up before
# the file has defined a single test, so the run reports a LoadError instead of a
# failing assertion, and a per-file suite run reads it as noise. That is exactly
# how test_agent_workspace_slug.rb sat for as long as it existed, with all seven
# of its assertions never once executed (ISS-634).
#
# Same guarded unshift as common.rb, and idempotent with it: both expand to the
# identical absolute path, so loading bin/dev afterwards is a no-op here.
lib = File.expand_path("../lib", __dir__)
$LOAD_PATH.unshift(lib) unless $LOAD_PATH.include?(lib)

# Shared across dev CLI tests: run a block that is expected to call `exit`,
# capturing whatever it wrote to stderr. Returns [stderr_string, exit_status]
# (status is nil if the block never exits). Include DevTestSupport in the test
# class to use it as an instance method.
module DevTestSupport
  # Raised when a test reaches the network instead of stubbing it. Loud and typed
  # so a test that WANTS to prove a command cannot escape can assert on it.
  class NetworkBlocked < StandardError; end

  # Raised when a test reads the REAL apps registry instead of naming a fleet.
  # See RegistryGuard.
  class RegistryBlocked < StandardError; end

  # The test process is credential-bearing by construction: this box holds a
  # human session, and inside a Claude session `dev` presents the AI's API token
  # (ApiClient.auth_header_for). So a test that calls a `cmd_*` function is one
  # missing guard away from writing to PRODUCTION - which is exactly what
  # happened: the issues arg-validation tests snoozed and re-fixed the real
  # ISS-034 dozens of times.
  #
  # The fix is to make the network unreachable by default rather than to stub
  # credentials test by test: every credential accessor reads as "not logged in"
  # and every request raises. A test that legitimately exercises a request opts
  # back in with `with_stubbed_api` (or its own stub), which overrides these.
  module NetworkGuard
    ACCESSORS = %i[auth_header_for session_id_for ai_token].freeze

    def self.install
      return unless defined?(ApiClient)
      @saved = { request: ApiClient.method(:request) }
      ApiClient.define_singleton_method(:request) do |_endpoint, method, path, **_opts|
        raise DevTestSupport::NetworkBlocked,
              "test attempted a live API request: #{method.to_s.upcase} #{path} - " \
              "stub it with with_stubbed_api instead of letting it reach the network"
      end
      ACCESSORS.each do |name|
        next unless ApiClient.respond_to?(name)
        @saved[name] = ApiClient.method(name)
        ApiClient.define_singleton_method(name) { |*_args, **_kwargs| nil }
      end
    end

    def self.uninstall
      return unless defined?(ApiClient) && @saved
      @saved.each { |name, original| ApiClient.define_singleton_method(name, original) }
      @saved = nil
    end
  end

  # NetworkGuard covers `dev`. ApibuilderClient is the OTHER HTTP client in this
  # repo -- a separate class, used by `bin/api`, that never routes through
  # ApiClient -- so none of the above touched it and it talked to
  # api.apibuilder.io unguarded.
  #
  # Guarding it means guarding `build_http`, not the three public entry points:
  # `raw_request`, `download` and `anonymous_init` each build their own request
  # object but all three obtain their connection here, so this is the one place
  # that cannot be bypassed by adding a fourth. Same rule as ISS-034 -- block the
  # REQUEST, not the credential, because there is always another credential.
  module ApibuilderGuard
    def self.install
      return unless defined?(ApibuilderClient)
      @saved = ApibuilderClient.instance_method(:build_http)
      ApibuilderClient.define_method(:build_http) do |uri|
        raise DevTestSupport::NetworkBlocked,
              "test attempted a live apibuilder request: #{uri} - " \
              "stub it rather than letting it reach the network"
      end
    end

    def self.uninstall
      return unless defined?(ApibuilderClient) && @saved
      ApibuilderClient.define_method(:build_http, @saved)
      @saved = nil
    end
  end

  # The same reasoning as NetworkGuard, for the machine instead of the network.
  #
  # `dev agent tick` now runs runner-local housekeeping (Agent::Maintenance,
  # ISS-520), which shells out to `dev aidirs prune --apply` and `dev docker
  # prune --apply`. Neither of those is scoped by a DEV_AGENT_* override: aidirs
  # hard-codes ~/code/ai and docker talks to whatever daemon is running. So any
  # test that exercises a tick is one missing override away from deleting the
  # developer's own feature dirs and Docker images — the same accident
  # NetworkGuard exists for, with no undo.
  #
  # The default answer is a clean no-op success rather than a raise, because a
  # test about the tick's OTHER behaviour should not have to know this exists. A
  # test that wants the real shell path opts back in with
  # `stub_singleton(Agent::Maintenance, :run_shell) { ... }`.
  # `run_gc` is guarded for the SAME reason and is the sharper edge of the two:
  # the shell-outs at least go through `dev`, but run_gc calls Agent::Gc.apply
  # directly, which is a bare `FileUtils.rm_rf` over Agent::Paths.workspace_root
  # -- and that root defaults to the developer's real ~/code/ai whenever
  # DEV_AGENT_WORKSPACE_ROOT is unset. It is scoped by Gc::AGENT_SLUG
  # (/\Ai\d+_[a-z0-9]{3}\z/), which is narrower than "everything" and wider than
  # "nothing": ~/code/ai/i576_yuz on this box matches it today.
  #
  # Nothing is deleted right now only because the one test file that calls
  # Agent::Maintenance.run happens to wrap every call in its own with_agent_home.
  # That is a property of that file, not of the guard, and the next test to call
  # `run` (or cmd_agent_maintenance) without repeating the override deletes for
  # real. Guarding both chores is what makes the safety structural.
  module MaintenanceGuard
    STUBBED = "stubbed by DevTestSupport::MaintenanceGuard".freeze

    def self.install
      return unless defined?(Agent::Maintenance)
      @saved = { :run_shell => Agent::Maintenance.method(:run_shell),
                 :run_gc => Agent::Maintenance.method(:run_gc),
                 :run_processes => Agent::Maintenance.method(:run_processes) }
      Agent::Maintenance.define_singleton_method(:run_shell) do |source, _trigger|
        Agent::Maintenance::Outcome.new(source: source, label: source.tr("_", " "), ok: true, message: STUBBED)
      end
      Agent::Maintenance.define_singleton_method(:run_gc) do |_now, _trigger|
        Agent::Maintenance::Outcome.new(source: Agent::Maintenance::GC_SOURCE, label: "agent gc",
                                        ok: true, message: STUBBED)
      end
      # The third chore SIGKILLs, so leaving it real is worse than leaving the
      # other two real — those delete files under a tmpdir the test already
      # overrode, while this one reads the WHOLE MACHINE and cannot be scoped by
      # any DEV_AGENT_* env var. Unstubbed it does exactly that: running this
      # suite while writing ISS-782 reaped twenty real orphaned processes off the
      # box, correctly by its own predicate and entirely without being asked.
      # A developer running `rake` must never have their machine's processes
      # killed as a side effect, and the blast radius of a predicate bug found
      # this way is every session on the runner.
      Agent::Maintenance.define_singleton_method(:run_processes) do
        Agent::Maintenance::Outcome.new(source: Agent::Maintenance::PROCESSES_SOURCE,
                                        label: "process reap", ok: true, message: STUBBED)
      end
    end

    def self.uninstall
      return unless defined?(Agent::Maintenance) && @saved
      @saved.each { |name, original| Agent::Maintenance.define_singleton_method(name, original) }
      @saved = nil
    end

    # The real method, for the one kind of test that is ABOUT it. See
    # `with_real_run_shell`, which is the only supported way to ask.
    def self.real(name) = @saved.fetch(name)
  end

  # The same reasoning again, for the toolchain probe the tick runs once a day
  # (Agent::Toolchain, ISS-531).
  #
  # Left real, it makes every tick test depend on WHAT IS INSTALLED ON THE BOX
  # RUNNING THE SUITE: a developer machine without `depsguard` would have the
  # tick try to file an issue about it, which NetworkGuard raises on — and
  # NetworkBlocked is not an ApiError, so it escapes the tick's rescue and fails
  # a test that was about something else entirely. It also shells out to
  # `/bin/zsh -lc` per call, which is real cost in a suite that runs the tick
  # dozens of times.
  #
  # The default is a healthy machine, for the same reason MaintenanceGuard's is a
  # clean success. A test that cares opts back in by stubbing `check` itself.
  module ToolchainGuard
    def self.install
      return unless defined?(Agent::Toolchain)
      @saved = Agent::Toolchain.method(:check)
      Agent::Toolchain.define_singleton_method(:check) do |tools: Agent::Toolchain::TOOLS, now: Time.now, **_opts|
        found = tools.map do |tool|
          # `unsupported_reason: nil` stated rather than defaulted: a healthy
          # machine is one where nothing is absent AND nothing is present at an
          # unusable version (ISS-781), and the stand-in should say both.
          Agent::Toolchain::Found.new(tool: tool, path: "/stubbed/bin/#{tool.name}",
                                      version: nil, unsupported_reason: nil)
        end
        Agent::Toolchain::Result.new(at: now, path: "/stubbed/bin", found: found)
      end
    end

    def self.uninstall
      return unless defined?(Agent::Toolchain) && @saved
      Agent::Toolchain.define_singleton_method(:check, @saved)
      @saved = nil
    end
  end

  # The same reasoning once more, for the external-API credentials a claimed
  # session is handed (Agent::Credentials, ISS-570).
  #
  # Left real, `probe` reads the env repo BESIDE THE DEVOPS CHECKOUT the suite is
  # running from — so a prompt test would render "available" on Mike's machine
  # and "NOT available" in a feature-dir clone with no sibling env/, and a tick
  # test would pull a live API key into a spawn environment for no reason. The
  # stand-in is a healthy machine, matching ToolchainGuard.
  #
  # `probe` is the one stub because it is the single read behind both public
  # faces: stubbing it keeps `check` and `resolve` agreeing, which stubbing them
  # separately would not. A test that is ABOUT this module opts out with
  # `uninstall` and stubs `probe` (or `EnvironmentVariables.lookup`) itself.
  module CredentialsGuard
    def self.install
      return unless defined?(Agent::Credentials)
      @saved = Agent::Credentials.method(:probe)
      Agent::Credentials.define_singleton_method(:probe) do |credential, **_opts|
        [:present, "stub-#{credential.name}", :env_repo]
      end
    end

    def self.uninstall
      return unless defined?(Agent::Credentials) && @saved
      Agent::Credentials.define_singleton_method(:probe, @saved)
      @saved = nil
    end
  end

  # The same reasoning once more, for the apps registry every deploy path
  # resolves a deployable through (Work::Registry, ISS-795).
  #
  # This one is leaked state as well as machine state, because `cached_registry`
  # memoizes it in a GLOBAL (`$cached_registry ||= Work::Registry.load`). So it
  # crosses test boundaries in both directions: a test that loads the registry
  # hands its fleet to every later test in the process, and a test that stubs
  # `Work::Registry.load` has NO effect at all once an earlier one has already
  # filled the global. Left real, `load` shells out to `pkl eval` once per app
  # under ~/code/env/apps, so the fleet a test asserts on is whatever this
  # machine happens to have checked out — and how long that takes depends on what
  # else is running on the box, which is why the failure it produced showed up
  # only under load.
  #
  # A raise rather than a benign stand-in, unlike MaintenanceGuard: a test that
  # reaches the registry is not one that incidentally touched the machine, it is
  # one whose subject IS the fleet, and there is no honest default fleet to hand
  # it. A test that needs one names it (`DeployRegistryFake#with_registry`, or
  # `DeployReleaseStubs#stub_release_seams` for the release path).
  #
  # Resetting the global is the half that cannot be opted out of: install and
  # uninstall both clear it, so no memoized registry survives a test either way.
  module RegistryGuard
    def self.install
      $cached_registry = nil
      return unless defined?(Work::Registry)
      @saved = Work::Registry.method(:load)
      Work::Registry.define_singleton_method(:load) do |**_opts|
        raise DevTestSupport::RegistryBlocked,
              "test read the REAL apps registry: Work::Registry.load shells out to `pkl eval` over " \
              "~/code/env/apps, so the fleet it returns is whatever this machine has checked out - " \
              "name a fleet instead (include DeployRegistryFake and use with_registry, or " \
              "DeployReleaseStubs#stub_release_seams)"
      end
    end

    def self.uninstall
      $cached_registry = nil
      return unless defined?(Work::Registry) && @saved
      Work::Registry.define_singleton_method(:load, @saved)
      @saved = nil
    end
  end

  # The same reasoning once more, for the lane walk the tick does looking for
  # commits to verify (Agent::Verify, ISS-848).
  #
  # `scan` is `gh pr list` against every repo in the lane — a dozen live GitHub
  # calls, whose answer is whatever pull requests happen to be open on the account
  # while the suite runs. Left real, `test_dry_run_walks_every_phase_and_executes_
  # nothing` made every one of them, on every run: slow, flaky by construction,
  # and reaching the network from a test — which is the thing NetworkGuard exists
  # to make impossible for the platform API and could not cover here, because this
  # one shells out to `gh` rather than going through ApiClient.
  #
  # An empty scan rather than a raise, matching MaintenanceGuard: reaching this is
  # not a test whose subject is the fleet, it is a test that walked the tick and
  # incidentally passed through it. A test that IS about the scan stubs it itself
  # (see test_agent_verify.rb), which overrides this.
  #
  # `claim` is stubbed too and is the one that would MUTATE: it posts a `pending`
  # commit status to a real repository.
  module VerifyGuard
    def self.install
      return unless defined?(Agent::Verify)
      @saved = { scan: Agent::Verify.method(:scan), claim: Agent::Verify.method(:claim) }
      Agent::Verify.define_singleton_method(:scan) do |**_opts|
        Agent::Verify::Scan.new(candidates: [], dropped: 0, included_main: false)
      end
      Agent::Verify.define_singleton_method(:claim) { |_candidate, **_opts| nil }
    end

    def self.uninstall
      return unless defined?(Agent::Verify) && @saved
      @saved.each { |name, original| Agent::Verify.define_singleton_method(name, original) }
      @saved = nil
    end

    # The real methods, for the one file that is ABOUT them. See
    # `with_real_verify`, which is the only supported way to ask.
    def self.real(name) = @saved.fetch(name)
  end

  # Wraps every test in every class that loads this helper. `before_setup` /
  # `after_teardown` rather than `setup` / `teardown` so a test class defining
  # its own setup cannot silently drop the guard.
  module GuardEveryTest
    def before_setup
      super
      DevTestSupport::NetworkGuard.install
      DevTestSupport::ApibuilderGuard.install
      DevTestSupport::MaintenanceGuard.install
      DevTestSupport::ToolchainGuard.install
      DevTestSupport::CredentialsGuard.install
      DevTestSupport::RegistryGuard.install
      DevTestSupport::VerifyGuard.install
    end

    def after_teardown
      DevTestSupport.restore_stubbed_globals(@dev_test_stubbed_globals)
      @dev_test_stubbed_globals = nil
      DevTestSupport::VerifyGuard.uninstall
      DevTestSupport::RegistryGuard.uninstall
      DevTestSupport::CredentialsGuard.uninstall
      DevTestSupport::ToolchainGuard.uninstall
      DevTestSupport::MaintenanceGuard.uninstall
      DevTestSupport::ApibuilderGuard.uninstall
      DevTestSupport::NetworkGuard.uninstall
      super
    end
  end

  # Name the fleet the commands under test resolve deployables against, for the
  # rest of the test. This is how a test opts out of RegistryGuard's raise: the
  # guard saved the real `load` before installing, so it restores that afterwards
  # however many times a test replaces it. Clearing the memo is the other half —
  # `cached_registry` would otherwise keep handing back a fleet named earlier.
  #
  # Block-scoped instead when the fleet is the subject rather than the setting:
  # DeployRegistryFake#with_registry.
  def registry_fleet(registry)
    Work::Registry.define_singleton_method(:load) { |**_opts| registry }
    $cached_registry = nil
    registry
  end

  # Run a block on a box that IS logged in — the normal state of every machine and
  # every Claude session. Use it to prove that a credential is not, on its own,
  # enough to let a test reach production.
  def with_credentials
    orig = ApiClient.method(:session_id_for)
    ApiClient.define_singleton_method(:session_id_for) { |app, use_localhost:| "sess-#{app}" }
    yield
  ensure
    ApiClient.define_singleton_method(:session_id_for, orig)
  end

  # Run a block with $stdout claiming to be a terminal. Output that adapts to a
  # tty (Util.hyperlink) is otherwise untestable: a StringIO reports tty? false,
  # which is exactly the non-terminal branch. Returns the block's value.
  def with_tty_stdout
    buf = StringIO.new
    buf.define_singleton_method(:tty?) { true }
    old = $stdout
    $stdout = buf
    yield
  ensure
    $stdout = old
  end

  # Run a block with $stdin replaced by `text`, reporting tty? as `tty`. Commands
  # that branch on $stdin.tty? (whether there is anyone to prompt) have two
  # genuinely different behaviours, and only this makes the non-terminal one — the
  # one every Claude session and cron run takes — testable.
  def with_stdin(text, tty: false)
    buf = StringIO.new(text)
    buf.define_singleton_method(:tty?) { tty }
    old = $stdin
    $stdin = buf
    yield
  ensure
    $stdin = old
  end

  # Everything the block wrote to $stdout, as a String.
  def capture_stdout
    buf = StringIO.new
    old = $stdout
    $stdout = buf
    yield
    buf.string
  ensure
    $stdout = old
  end

  def capture_stderr_and_exit
    buf = StringIO.new
    old = $stderr
    $stderr = buf
    status = nil
    begin
      yield
    rescue SystemExit => e
      status = e.status
    end
    [buf.string, status]
  ensure
    $stderr = old
  end

  # Run a block with every ApiClient request answered from `responses`, keyed by
  # "GET /path". A request with no stubbed key fails the test rather than hitting
  # the network. Credentials are stubbed present here - NetworkGuard reads them as
  # absent, which would stop a command at its credential guard before it ever got
  # to the request under test.
  #
  # A stubbed value that responds to #call is called with the request body and its
  # return value is the response - which is how a test asserts on what was SENT
  # (a form field, a payload shape) rather than only on what came back.
  def with_stubbed_api(responses)
    test = self
    orig_request = ApiClient.method(:request)
    orig_sid = ApiClient.method(:session_id_for)
    ApiClient.define_singleton_method(:request) do |_endpoint, method, path, **opts|
      key = "#{method.to_s.upcase} #{path}"
      test.flunk("unstubbed request: #{key}") unless responses.key?(key)
      stubbed = responses.fetch(key)
      stubbed.respond_to?(:call) ? stubbed.call(opts[:body]) : stubbed
    end
    ApiClient.define_singleton_method(:session_id_for) { |app, use_localhost:| "sess-#{app}" }
    yield
  ensure
    ApiClient.define_singleton_method(:request, orig_request)
    ApiClient.define_singleton_method(:session_id_for, orig_sid)
  end

  # Replace a singleton method (`Open3.capture2e`, …) for the duration of a
  # block. Minitest's own `Object#stub` is NOT available here — minitest 6
  # stopped loading `minitest/mock` from `minitest/autorun` — so tests that
  # reach for it fail with "undefined method 'stub'". This is the substitute.
  def stub_singleton(obj, name, impl)
    original = obj.method(name)
    obj.define_singleton_method(name, &impl)
    yield
  ensure
    obj.define_singleton_method(name, original)
  end

  # Stubs the ONE place lib/agent shells out (Agent::Shell.capture — ISS-740, and
  # test_dev_agent_shell.rb keeps it the only one). `impl` receives the command
  # as an array and the options hash, so a test asserts on the flags that were
  # passed as well as on what came back.
  def stub_shell(impl, &block)
    stub_singleton(Agent::Shell, :capture, ->(*cmd, **opts) { impl.call(cmd, opts) }, &block)
  end

  # The REAL Agent::Verify.scan / .claim, for the one file whose subject they are.
  #
  # VerifyGuard neuters both for every other test in the suite, so a test about
  # the scan has to ask for them back — and gets them only together with whatever
  # stub the caller then installs over `Agent::Shell.capture` or
  # `Agent::MergeLane.open_prs`, which is what keeps the network out.
  def with_real_verify(&block)
    stub_singleton(Agent::Verify, :scan, DevTestSupport::VerifyGuard.real(:scan)) do
      stub_singleton(Agent::Verify, :claim, DevTestSupport::VerifyGuard.real(:claim), &block)
    end
  end

  # The REAL Agent::Maintenance.run_shell, for a test about run_shell itself.
  #
  # MaintenanceGuard replaces it globally so that no suite run can prune the
  # machine it is running on, and handing it back on its own would defeat that.
  # So it comes with the shell stub attached: the real chore logic runs and the
  # subprocess it would have spawned does not exist. There is deliberately no
  # way to ask for one without the other.
  def with_real_run_shell(impl, &block)
    stub_singleton(Agent::Maintenance, :run_shell, MaintenanceGuard.real(:run_shell)) do
      stub_shell(impl, &block)
    end
  end

  # What Agent::Shell.capture would have returned. `timed_out: true` is a killed
  # command, which is why it has no exit status of its own.
  def shell_result(output: "", exitstatus: 0, timed_out: false, timeout: 60)
    status = timed_out ? nil : Struct.new(:success?, :exitstatus).new(exitstatus.zero?, exitstatus)
    Agent::Shell::Result.new(output: output, status: status, timed_out: timed_out, timeout: timeout)
  end

  # Same, for a top-level `dev` function (they land as private methods on
  # Object, so a test calls them as bare methods and this replaces them).
  def stub_global(name, impl)
    original = method(name)
    Object.send(:define_method, name, &impl)
    yield
  ensure
    Object.send(:define_method, name, original)
  end

  # Same substitution, scoped to the whole test rather than to a block. A setup
  # that replaces every boundary a command crosses (`dev changelog build` stubs
  # nine) is unreadable as nine nested blocks, and the stubs have to outlive
  # setup anyway. GuardEveryTest restores them after every test: a global stub
  # lands on Object, so one left behind is visible to every later test in the
  # process, not just this class.
  def stub_global_for_test(name, &body)
    @dev_test_stubbed_globals ||= {}
    unless @dev_test_stubbed_globals.key?(name)
      @dev_test_stubbed_globals[name] = begin
        Object.instance_method(name)
      rescue NameError
        nil
      end
    end
    Object.send(:define_method, name, body)
  end

  # Put back everything stub_global_for_test replaced. A name that did not exist
  # before is removed rather than restored — define_method(name, nil) raises.
  def self.restore_stubbed_globals(stubs)
    stubs&.each do |name, original|
      if original
        Object.send(:define_method, name, original)
      else
        Object.send(:remove_method, name)
      end
    end
  end
end

Minitest::Test.prepend(DevTestSupport::GuardEveryTest)

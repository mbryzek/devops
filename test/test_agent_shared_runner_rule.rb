#!/usr/bin/env ruby
require 'minitest/autorun'
require_relative 'test_helper'
require 'agent/paths'
require 'agent/processes'
require 'agent/prompt'

# The shared-runner threat model, and the three places it has to stay stated
# together (ISS-1028).
#
# ISS-961 fixed argv: "never write the value into a command line — pass $NAME,
# never what it resolves to", because `ps -U <uid>` shows every argument of every
# sibling's processes. That is true, and read alone it teaches the wrong lesson.
# The implicature a session takes from it is that the ENVIRONMENT is the safe
# place to keep a credential and argv is the leaky one. Both are readable, and
# the environment is WORSE on duration: an inlined key is exposed for the seconds
# a curl runs, an inherited one for the hours a session lives. Measured on a
# runner on 2026-08-08 with a canary of my own, never a sibling's:
#
#     $ I1028_PROBE=canary-not-a-secret ruby -e 'sleep 45' &
#     $ /bin/ps -Eax | grep -o "I1028_PROBE=[a-z-]*"
#     I1028_PROBE=canary-not-a-secret
#
# Two corrections to the report, both of which make the hazard sharper rather
# than softer, and both of which this file pins so they cannot drift back:
#
#   THE FLAG.   ISS-1028 reported `ps -E -p <pid>`. That is not the disclosing
#               form: `-E` appends the environment only in the DEFAULT output
#               format, is silently ignored alongside `-o`, and adds nothing to a
#               bare `-p`. It reproduced anyway because `ps` is aliased to
#               `ps -ax` (`~/code/misc/env/.alias`) — so a command scoped to one
#               child listed the whole machine instead.
#   THE TARGET. `/bin/sleep` discloses NOTHING; macOS withholds the environment
#               of an Apple platform binary. It hands over everything else, which
#               is exactly the set a session runs — `claude` itself, node, ruby,
#               java, vite, every homebrew tool. Of 770 processes listed on this
#               runner, 88 disclosed an environment and 13 of those carried
#               PLAYBOOK_CLAUDE_KEY in plaintext.
#
# So the canary below is `ruby`, not `sleep`. A `sleep` canary would pass for the
# wrong reason today and go green forever the moment the hazard changed.
#
# So a session that obeys ISS-961 perfectly still holds nothing back from its
# siblings. Of the three fixes the issue weighed — say it plainly, broker
# short-lived tokens, one uid per session slot — this guards the first: the
# instructions stop implying a protection that does not exist, and say what the
# real boundary is instead.
#
# What that leaves is worth defending and this file pins all of it:
#
#   the RULE       `agent/instructions.md` §4, which is part 1 of every session's
#                  prompt. The boundary is the MACHINE, not the session; the
#                  thing to protect is the DURABLE artifact (transcript, PR,
#                  comment, plan, commit); harvesting is how a credential reaches
#                  one. §3 carries the prohibition itself, beside bare `env`,
#                  because it is a safety rule and not a review gate.
#   the PROMPT     `Agent::Prompt.credentials_section` states it at the point of
#                  use. A session reads its assignment block long before it reads
#                  §4 of a 1000-line file, and the per-credential line there is
#                  exactly the one that implied the environment was safe.
#   the CODE       `Agent::Processes` reads `ps` on every leak sweep. Adding `-E`
#                  to PS_FORMAT would copy every sibling's whole environment into
#                  a public struct field, on this fleet, forever.
#
# And the FACT underneath, probed rather than asserted from memory: if macOS ever
# stops disclosing a same-uid process's environment, the prose above is describing
# a hazard that no longer exists and deserves re-reading rather than outliving its
# reason. Same shape as test_agent_devops_merge_rule.rb.
class TestAgentSharedRunnerRule < Minitest::Test
  # Read per call rather than memoized: minitest inspects `self` on a failure,
  # and a 40KB ivar buries the assertion that failed.
  def instructions
    File.read(Agent::Paths.instructions_file)
  end

  def workspace_section
    section = instructions[/^## 4\. Your workspace.*?^## 5\./m]
    refute_nil section, "instructions.md no longer has a §4 / §5 to place the shared-runner rule between"
    section
  end

  def not_relaxed_section
    section = instructions[/^## 3\. What is NOT relaxed.*?^## 4\./m]
    refute_nil section, "instructions.md no longer has a §3 / §4"
    section
  end

  # Asserts on a boolean rather than with assert_match, which prints the whole
  # haystack: these sections are kilobytes of prose, and a failure that buries
  # its own message under what it was reading is a failure nobody reads.
  def assert_says(section, pattern, why)
    assert section.match?(pattern), "agent/instructions.md: #{why} (looked for #{pattern.inspect})"
  end

  # ---- the rule ----

  def test_the_rule_names_the_machine_as_the_boundary
    assert_says(workspace_section, /isolation boundary is the MACHINE, not your\s+session/,
                "§4 must say outright that a sibling session is not walled off from this one — " \
                "an argv-only warning implies the environment is the safe place to keep a key")
  end

  # The specific route ISS-961's wording left out. Naming the command is what
  # makes the claim checkable by the next session rather than a mood.
  def test_the_rule_names_the_environment_route_and_its_duration
    assert_says(workspace_section, /ps -Eax/,
                "§4 must name the form that actually discloses. `-E` is ignored alongside `-o` and adds " \
                "nothing to a bare `-p <pid>`; `ps -Eax` is the one that prints environments")
    assert_says(workspace_section, /hours a\s+session lives/,
                "§4 must say the environment is exposed for the LIFE of the session — the duration is " \
                "the whole reason it is worse than an inlined value, not a detail")
  end

  # The trap that made ISS-1028's own repro misleading, and the reason the rule
  # is "do not run these" rather than "scope them properly": a session that
  # narrows `ps -E` to one pid still gets the whole box, because the shell
  # rewrites the command underneath it.
  def test_the_rule_warns_that_the_shell_alias_widens_a_scoped_ps
    assert_says(workspace_section, /aliased to `ps -ax`/,
                "§4 must say `ps` is aliased on this fleet — a scoped `ps -E -p <pid>` becomes a dump " \
                "of every process's environment, which is how the reported repro 'worked'")
    assert_says(workspace_section, /770/,
                "§4 must carry the measured blast radius; a warning without a number reads as caution")
  end

  # The rule that survives the admission. Hiding a key from a sibling is not
  # possible; keeping it out of something permanent is, and that is the one a
  # session can actually act on.
  def test_the_rule_states_the_durable_artifact_as_the_thing_protected
    assert_says(workspace_section, /OUTLIVE the runner|outlives this\s+machine/,
                "§4 must say WHY the remaining rules exist once same-uid isolation is admitted to be absent")
    %w[transcript PR plan fixture commit].each do |artifact|
      assert_says(workspace_section, /#{artifact}/,
                  "§4 must enumerate the durable artifacts a credential must never reach (#{artifact})")
    end
  end

  # The safety half lives in §3, beside `env` — the same act by a different
  # command. §2 converts review gates into PR sections; this is not one of those,
  # and no artifact substitutes for not having read a sibling's secrets.
  def test_the_harvest_prohibition_is_in_the_not_relaxed_section
    assert_says(not_relaxed_section, /never HARVEST a sibling session's secrets/i,
                "reading another run's credentials is a safety rule, so it belongs in §3 with bare `env`")
    %w[ps\ -E ps\ auxww pgrep\ -fl].each do |command|
      assert_says(not_relaxed_section, /#{Regexp.escape(command)}/,
                  "§3 must name #{command} — a prohibition with no commands in it is unenforceable")
    end
    assert_says(not_relaxed_section, /dev issues workaround/,
                "§3 must say what to do INSTEAD about a credential you were not handed, or the rule " \
                "reads as an obstacle rather than a redirect")
  end

  # ISS-961's own guidance has to survive this rewrite. The two rules are
  # complementary — one keeps a key out of a listing, the other keeps a listing
  # out of a transcript — and dropping either while restating the threat model
  # would be a regression dressed as a clarification.
  def test_the_iss961_rules_are_still_stated
    assert_says(workspace_section, /Never write a resolved credential INTO a command/,
                "the argv rule is narrowed by ISS-1028, not replaced by it")
    assert_says(workspace_section, /pgrep -f <pattern>/,
                "the safe way to poll for a background process must still be spelled out")
    assert_says(workspace_section, /ISS-961/, "the incident the argv rule came from must stay attached to it")
  end

  # ---- the prompt ----
  #
  # §4 reaches a session that reads §4. The assignment block reaches every
  # session, and it is where the per-credential "never inline it" line lives —
  # the line whose omission this issue is about.
  def test_the_credentials_section_states_the_shared_runner_fact
    section = credentials_section
    assert_match(/isolation boundary is the MACHINE, not your session/, section,
                 "the assignment block must not leave a session believing its environment is private")
    assert_match(/ps -E/, section, "the assignment block must name the route")
    assert_match(/DURABLE artifact/, section, "the assignment block must state the rule that survives")
    assert_match(/§4/, section, "the assignment block must point at the full statement")
  end

  # Stated once, as a footer, because it is a fact about the MACHINE rather than
  # about any one key. Repeating it per credential would make a two-credential
  # runner say it twice and read as boilerplate.
  def test_the_shared_runner_fact_is_stated_once_regardless_of_credential_count
    assert_equal 1, credentials_section(count: 2).scan(/isolation boundary is the MACHINE/).length
  end

  # The section renders into the assignment block or it ships nothing.
  def test_the_assignment_block_carries_it
    assignment = Agent::Prompt.assignment(
      issue: { "number" => 1028, "title" => "t", "category" => "bug" },
      slug: "i1028", workspace: "/tmp/ws", credentials: credentials(1),
    )
    assert_match(/isolation boundary is the MACHINE/, assignment)
  end

  # ---- the code ----

  # `Agent::Processes.read` asks `ps` for a fixed field list on every leak sweep.
  # `-E` is ignored alongside `-o` on this `ps`, so adding it today would leak
  # nothing — which is an implementation detail of one binary, not a guarantee,
  # and it evaporates the moment somebody simplifies the call away from `-o`.
  # The sweep needs pids, ancestry and age and has never needed an environment,
  # so the cheap thing is to keep the flag out and not have to reason about it.
  # `Agent::Redact` runs over what comes back, but its own header calls itself
  # "a net, not a seal".
  def test_the_leak_sweep_never_asks_ps_for_an_environment
    refute_match(/\bE\b/, Agent::Processes::PS_FORMAT,
                 "PS_FORMAT must not request an environment column")
    argv = capture_ps_argv { Agent::Processes.read }
    refute_nil argv, "Agent::Processes.read no longer shells out to ps — re-read this test before deleting it"
    refute_includes argv, "-E",
                     "Agent::Processes.read now asks ps for every process's ENVIRONMENT — on this fleet, " \
                     "every sibling session's credentials. It happens to be inert next to `-o`; do not " \
                     "rely on that. agent/instructions.md §3 forbids harvesting them and devops must not " \
                     "do it either."
    refute_includes argv, "-e", "ps -e widens the sweep past this uid (`-U`), which is the other half of the rule"
  end

  # ---- the fact the rule rests on ----

  def test_a_same_uid_process_still_discloses_its_environment
    skip "ps -E is the macOS spelling; the fleet is macOS" unless RUBY_PLATFORM.include?("darwin")
    canary = "canary-not-a-secret"
    # `RbConfig.ruby` — the interpreter running this suite — rather than
    # `/bin/sleep`: macOS withholds an Apple platform binary's environment and
    # discloses everybody else's, so a `sleep` canary measures SIP and reports it
    # as safety. This one is the same class of binary as `claude`, `node` and
    # `java`, which is the class every credential on this box is held in.
    pid = Process.spawn({ "I1028_PROBE" => canary }, RbConfig.ruby, "-e", "sleep 10",
                        out: File::NULL, err: File::NULL)
    begin
      # `-Eax`, and an absolute `/bin/ps`, are both load-bearing: `-E` is inert
      # next to `-o` and next to a bare `-p`, and a relative `ps` would measure
      # whatever this shell aliased. This asks the narrowest question that is
      # still the real one.
      #
      # Polled, because `ps` sees the environment only once the child has exec'd
      # and `spawn` returns before that — a single immediate read is a coin flip.
      #
      # Piped through grep IN THE SHELL rather than read into Ruby and scanned:
      # `-ax` returns every process on the box, and this test must not pull any
      # OTHER session's environment into a CI log even transiently. That is the
      # hazard it exists to describe.
      disclosed = nil
      20.times do
        # `[a-z][a-z-]*` rather than `[a-z-]*`: `-ax` lists the grep itself, whose
        # own argv contains the pattern, and a `*` quantifier matches the literal
        # `I1028_PROBE=` in it with an empty value. Requiring one real character
        # skips that self-match without excluding the canary.
        disclosed = `/bin/ps -Eax 2>/dev/null | grep -o 'I1028_PROBE=[a-z][a-z-]*' | head -1`.strip
        break unless disclosed.empty?
        sleep 0.1
      end
      assert_equal "I1028_PROBE=#{canary}", disclosed,
                   "macOS no longer discloses a same-uid process's environment to `ps -E`. That is the " \
                   "premise the shared-runner rule in agent/instructions.md §3/§4 rests on — re-read the " \
                   "rule and this test's header before assuming it is still describing reality."
    ensure
      Process.kill("KILL", pid) rescue nil
      Process.wait(pid) rescue nil
    end
  end

  private

  # A present credential, shaped like the real ones and carrying no value — the
  # section under test is printed into prompt.md and quoted into issue comments.
  def credentials(count)
    Array.new(count) do |i|
      Agent::Credentials::Found.new(
        credential: Agent::Credentials::Credential.new(
          name: "FAKE_KEY_#{i}", source: Agent::Credentials::KeyFile.new(file: "fake"),
          required_by: "testing", how_to_provide: "set it", usage_example: "curl -H \"x-api-key: $FAKE_KEY_#{i}\" ...",
        ),
        status: :present, source: :env_repo,
      )
    end
  end

  def credentials_section(count: 1) = Agent::Prompt.credentials_section(credentials(count))

  # `Agent::Processes.read` goes through `Agent::Shell.capture`, so intercepting
  # there sees the real argv the module builds rather than a restatement of it.
  def capture_ps_argv
    seen = nil
    original = Agent::Shell.method(:capture)
    Agent::Shell.define_singleton_method(:capture) do |*argv, **opts|
      # Matched on the BASENAME: ISS-1033 made this call an absolute `/bin/ps`,
      # and a literal "ps" comparison would silently stop watching the very call
      # it exists to watch.
      seen = argv if File.basename(argv.first.to_s) == "ps"
      original.call(*argv, **opts)
    end
    yield
    seen
  ensure
    Agent::Shell.define_singleton_method(:capture, original)
  end
end

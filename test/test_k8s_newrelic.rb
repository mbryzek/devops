#!/usr/bin/env ruby
require 'minitest/autorun'
require_relative 'test_helper'
load File.expand_path('../bin/dev', __dir__)

# New Relic APM instrumentation, as decided by deploy config rather than by
# anything in an app's own source.
#
# Every assertion here is about ONE failure mode, and it is not "the agent is
# misconfigured" — a misconfigured agent announces itself. It is that an app can
# be *absent* from New Relic, because absent is indistinguishable from healthy:
# an NRQL query naming an app that reports nothing returns an empty result set,
# not an error (ISS-635). "No errors" and "not instrumented" are the same output,
# so nothing downstream can tell them apart and no alert can fire.
#
# Acumen was in that state for eighteen months. `GET /g/<group>/duplicate/
# transactions` returned 500 from February 2025 until August 2026 and was found
# by a human paging to the end of a queue (ISS-1056, ISS-1070), while the
# `daily-error-triage` playbook — which runs entirely on NerdGraph — reported a
# clean night every one of those nights, truthfully and uselessly.
#
# There are three ways into that state and each has a test below: the app config
# never says to instrument; the config says so but the deploy silently drops it;
# the agent attaches with no license key and fails to authenticate in silence.
class TestK8sNewRelic < Minitest::Test
  include DevTestSupport

  K8S       = File.expand_path('../k8s', __dir__)
  TEMPLATE  = File.read(File.join(K8S, 'templates/scala-play-app.pkl'))
  ACUMEN    = File.read(File.join(K8S, 'apps/acumen.pkl'))
  PLATFORM  = File.read(File.join(K8S, 'apps/platform.pkl'))
  DEPLOY    = File.read(File.expand_path('../bin/k8s-deploy', __dir__))
  SECRETS   = File.read(File.expand_path('../bin/k8s-secrets', __dir__))

  # --- 1. The app config says to instrument ---------------------------------

  def test_acumen_attaches_the_newrelic_agent
    assert_match(/^javaAgent = "\/opt\/newrelic\/newrelic\.jar"$/, ACUMEN,
                 "acumen must attach the New Relic agent. Without this line it reports " \
                 "nothing to account 7724695, and an acumen 500 leaves no signal in the " \
                 "only production source an autonomous session can query (ISS-1070).")
  end

  def test_platform_still_attaches_the_newrelic_agent
    assert_match(/^javaAgent = "\/opt\/newrelic\/newrelic\.jar"$/, PLATFORM,
                 "platform's instrumentation is the reference the acumen change was " \
                 "modelled on; if this ever stops being true the two have diverged.")
  end

  # The jar is in every image whether or not the app is instrumented, so its
  # presence proves nothing and must not be mistaken for evidence.
  def test_agent_jar_is_baked_into_every_scala_play_image
    dockerfile = File.read(File.expand_path('../templates/Dockerfile.scala-play', __dir__))
    assert_match(%r{COPY --from=newrelic /opt/newrelic/newrelic\.jar}, dockerfile,
                 "Every scala-play image ships the agent jar. That is why attaching it to " \
                 "acumen needed no image or application change — and why `javaAgent` in the " \
                 "app config, not the jar on disk, is what says an app is instrumented.")
  end

  # --- 2. The deploy does not silently drop it ------------------------------

  def test_deploy_reads_app_config_through_the_aborting_loader
    assert_match(/K8sAppConfig\.load\(args\.app\)/, DEPLOY,
                 "k8s-deploy must read app config through K8sAppConfig, which aborts on " \
                 "failure.")
    refute_match(/rescue \{\}/, DEPLOY,
                 "`JSON.parse(...) rescue {}` is how this fails silently: any error — bad " \
                 "pkl, missing binary, misspelled app — becomes an empty hash, an empty " \
                 "hash has no javaAgent, and the deploy SUCCEEDS having quietly shipped " \
                 "the app with its instrumentation removed.")
  end

  def test_unknown_app_aborts_and_names_the_apps_that_exist
    err, status = capture_stderr_and_exit { K8sAppConfig.load("no-such-app") }
    assert_equal 1, status, "an unreadable app config must abort, never return {}"
    assert_match(/no-such-app/, err)
    assert_match(/Available:.*acumen.*platform/m, err,
                 "naming the apps that do exist turns a typo into a one-line fix instead " \
                 "of a silently un-instrumented deploy")
  end

  def test_java_agent_detection_treats_absent_and_blank_alike
    assert K8sAppConfig.java_agent?("javaAgent" => "/opt/newrelic/newrelic.jar")
    refute K8sAppConfig.java_agent?({})
    refute K8sAppConfig.java_agent?("javaAgent" => "")
    refute K8sAppConfig.java_agent?("javaAgent" => "   "),
           "a whitespace-only path would render `-javaagent: ` and fail the JVM at boot"
  end

  # `if config['distributedTracing']` reads naturally and is wrong: `false` is
  # the only value this setting is ever set to, and Ruby truthiness would drop
  # it, restoring the default (enabled) with nothing to show that it happened.
  def test_deploy_passes_distributed_tracing_by_presence_not_truthiness
    assert_match(/unless config\['distributedTracing'\]\.nil\?/, DEPLOY,
                 "must test nil?, not truthiness — `false` is the whole point of the " \
                 "setting and truthiness silently discards it")
  end

  # --- 3. The agent has the key it needs ------------------------------------

  def test_k8s_secrets_refuses_to_sync_an_instrumented_app_with_no_license_key
    assert_match(/K8sAppConfig\.java_agent\?\(k8s_config\)/, SECRETS)
    assert_match(/K8sAppConfig::LICENSE_KEY\]\.to_s\.strip\.empty\?/, SECRETS)
    assert_match(/Util\.exit_with_error/, SECRETS,
                 "The check must ABORT. An agent that attaches without a license key does " \
                 "not crash — it starts, fails to authenticate, and reports nothing for as " \
                 "long as the app runs. A warning would scroll past; this is the last " \
                 "moment both halves of the pair are visible at once.")
  end

  def test_license_key_variable_is_named_once
    assert_equal "NEW_RELIC_LICENSE_KEY", K8sAppConfig::LICENSE_KEY,
                 "the guard and its remediation message must not be able to drift apart " \
                 "from the variable k8s-secrets actually syncs"
  end

  # --- The tracing setting ---------------------------------------------------

  def test_acumen_disables_distributed_tracing
    assert_match(/^distributedTracing = false$/, ACUMEN,
                 "acumen is a single standalone service with nothing downstream " \
                 "instrumented, so distributed tracing ships spans describing a call graph " \
                 "that never leaves the process. Measured 2026-08-08, tracing was 30.7 GB " \
                 "of the account's 76.5 GB / 30 days against a 100 GB free-tier ceiling.")
  end

  def test_errors_are_not_what_tracing_pays_for
    assert_match(/TransactionError carries the class, message and stack trace/, TEMPLATE,
                 "The reason disabling tracing is safe for this issue's purpose must stay " \
                 "written down next to the setting: error identity does not come from " \
                 "spans, so turning tracing off costs nothing that ISS-1070 asked for.")
  end

  # An app that says nothing about tracing must still render the JAVA_OPTS it
  # rendered before this setting existed. Asserted structurally — an unset value
  # contributes the empty string — because the alternative is a rendered-manifest
  # comparison that needs a pkl binary the rest of this suite deliberately never
  # depends on. Every app in k8s/apps/ sets it today, so nothing exercises this
  # branch; it is what keeps adding an app a one-line change.
  def test_tracing_flag_is_emitted_only_when_an_app_sets_it
    assert_match(/local distributedTracing = read\?\("env:NEWRELIC_DISTRIBUTED_TRACING"\) \?\? ""/, TEMPLATE)
    assert_match(/if \(distributedTracing == ""\) "" else "-Dnewrelic\.config\.distributed_tracing\.enabled=/, TEMPLATE,
                 "unset must contribute the empty string, so an app that says nothing " \
                 "about tracing renders the JAVA_OPTS it rendered before this setting " \
                 "existed")
  end

  # Platform is the ONLY app here with two instrumented tiers, so it is the only
  # place a trace could cross a service boundary — and the measurement is that
  # none does (ISS-1084). Turning tracing off is therefore the same decision
  # acumen made, not a different one, and the evidence has to stay next to the
  # setting: this is the assertion that fails if someone flips it back without
  # re-measuring.
  def test_platform_disables_distributed_tracing
    assert_match(/^distributedTracing = false$/, PLATFORM,
                 "platform's traces never leave one process — 97.8% of its transactions " \
                 "are trace entry points and no trace contains more than one application, " \
                 "because platform-web reaches platform-job through a database task queue. " \
                 "Tracing was 40% of the account's ingest (0.87-1.52 GB/day of 2.80) " \
                 "against a 100 GB free tier August was projected to reach 87% of.")
    assert_match(/nr\.entryPoint/, PLATFORM,
                 "the query that established the premise must stay next to the setting, " \
                 "so flipping it back is a re-measurement rather than a guess")
  end

  # The two apps reach the same conclusion from the same evidence, and the day
  # they stop agreeing is the day one of them was changed without the other
  # being reconsidered.
  def test_both_apps_turn_tracing_off_and_say_why
    [["acumen", ACUMEN], ["platform", PLATFORM]].each do |app, config|
      assert_match(/^distributedTracing = false$/, config, "#{app} must disable tracing")
      assert_match(/never leaves the process|begins and ends inside one process/, prose(config),
                   "#{app} must say WHY next to the setting — a bare `false` reads as a " \
                   "cost cut, and the reason it is safe (nothing to trace into) is the " \
                   "only thing that says when to revisit it")
    end
  end

  # A claim in a comment wraps wherever the line ran out, so matching one against
  # the raw file asserts where the author pressed return as much as what they
  # said. Strips comment markers and collapses whitespace so the assertion is
  # about the sentence.
  def prose(config) = config.gsub(%r{^\s*//+}, " ").gsub(/\s+/, " ")

  def test_tracing_flag_is_inside_the_agent_branch
    flags = TEMPLATE[/local function javaAgentFlags.*$/, 0]
    refute_nil flags, "javaAgentFlags must still exist"
    assert_match(/if \(javaAgent == ""\) ""/, flags)
    assert_match(/distributedTracingFlag/, flags,
                 "the tracing flag must sit inside the `javaAgent == \"\"` branch — " \
                 "a -Dnewrelic.config.* property on a JVM with no agent attached is dead " \
                 "config that reads like instrumentation")
  end
end

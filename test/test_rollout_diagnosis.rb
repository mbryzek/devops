#!/usr/bin/env ruby
require 'minitest/autorun'
require_relative '../lib/common'
require_relative 'test_helper'

# The platform 0.18.83-0.18.85 outage took three deploys to resolve because the
# failure output could not tell two opposite situations apart:
#
#   0.18.83  the new image was genuinely broken (malformed logback.xml)
#   0.18.85  the image was FIXED, but platform-job-0 was deadlocked on 0.18.83
#            and never received it
#
# Same pod, same CrashLoopBackOff, same log lines — because the stuck pod was
# still executing the old broken image. Two good releases in a row read as
# failures. These pin the distinction.
class TestRolloutDiagnosis < Minitest::Test
  include DevTestSupport

  K8S_DEPLOY = File.read(File.expand_path('../bin/k8s-deploy', __dir__))

  def pod(name, image, ready) = {name: name, image: image, ready: ready}

  def test_healthy_rollout_says_nothing
    pods = [pod("platform-web-a", "platform:0.18.85", true)]
    assert_empty RolloutDiagnosis.explain(workload: "platform-web", desired_image: "platform:0.18.85", pods: pods)
  end

  def test_broken_new_image_is_called_an_application_failure
    pods = [pod("platform-job-0", "platform:0.18.83", false)]
    lines = RolloutDiagnosis.explain(workload: "platform-job", desired_image: "platform:0.18.83", pods: pods)
    text = lines.join("\n")
    assert_match(/application startup failure/i, text,
                 "The pod IS on the deployed tag, so the code is what is broken.")
    refute_match(/DEADLOCK/i, text)
  end

  def test_pod_stuck_on_an_older_image_is_called_a_deadlock
    pods = [pod("platform-job-0", "platform:0.18.83", false)]
    lines = RolloutDiagnosis.explain(workload: "platform-job", desired_image: "platform:0.18.85", pods: pods)
    text = lines.join("\n")
    assert_match(/DEADLOCKED ROLLOUT/, text,
                 "Pod is on 0.18.83 while the spec wants 0.18.85 — it never got the " \
                 "new image, so the running code is not what was just deployed.")
    assert_match(/will NOT fix this/, text,
                 "The operator's instinct is to cut another tag. That is precisely " \
                 "what does not work, and it cost two releases.")
    assert_match(/kubectl delete pod -n <namespace> platform-job-0/, text,
                 "Must name the exact remediation — deleting the pod is the only exit.")
  end

  def test_deadlock_reports_both_the_wanted_and_the_running_image
    pods = [pod("platform-job-0", "platform:0.18.83", false)]
    text = RolloutDiagnosis.explain(workload: "platform-job", desired_image: "platform:0.18.85", pods: pods).join("\n")
    assert_match(/spec wants: platform:0\.18\.85/, text)
    assert_match(/still running: platform-job-0 on platform:0\.18\.83/, text)
  end

  def test_ready_pods_are_never_reported_even_when_on_an_old_image
    # Mid-rollout an old-image pod that is still Ready is normal, not a fault.
    pods = [pod("platform-web-old", "platform:0.18.84", true)]
    assert_empty RolloutDiagnosis.explain(workload: "platform-web", desired_image: "platform:0.18.85", pods: pods)
  end

  def test_mixed_fleet_reports_only_the_stuck_pod
    pods = [
      pod("platform-web-new", "platform:0.18.85", true),
      pod("platform-job-0",   "platform:0.18.83", false),
    ]
    text = RolloutDiagnosis.explain(workload: "platform", desired_image: "platform:0.18.85", pods: pods).join("\n")
    assert_match(/platform-job-0/, text)
    refute_match(/platform-web-new/, text)
  end

  # The bug that hid the root cause for the entire first round: a
  # CrashLoopBackOff pod has phase "Running", so a phase-based filter matches
  # nothing and the script printed no logs at all.
  def test_failing_pod_selection_is_not_based_on_phase
    refute_match(/status\.phase!="Running"/, K8S_DEPLOY,
                 "A CrashLoopBackOff pod has phase Running. Selecting on phase finds " \
                 "nothing and prints no logs on the one failure this code exists for.")
    assert_match(/reject \{ \|p\| p\[:ready\] \}/, K8S_DEPLOY,
                 "Failing pods must be selected on container readiness.")
  end

  def test_diagnosis_is_printed_before_the_logs
    diag = K8S_DEPLOY.index('puts "Diagnosis:"')
    logs = K8S_DEPLOY.index('puts "Checking for failing pods..."')
    refute_nil diag
    refute_nil logs
    assert diag < logs,
           "The logs of a deadlocked pod are the OLD image's logs and read as a " \
           "code failure. The diagnosis has to frame them before they scroll past."
  end
end

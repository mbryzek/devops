#!/usr/bin/env ruby
require 'minitest/autorun'
require_relative 'test_helper'

# platform-job-0 crashlooped on 0.18.83 (a malformed logback.xml) and then could
# not be recovered by 0.18.84 or 0.18.85, both of which contained the fix. With
# podManagementPolicy OrderedReady the StatefulSet controller returns early from
# its sync the moment it sees a pod that is not Running-and-Ready, before
# reaching the rolling-update phase that would replace it — so the pod kept
# executing the original broken image and no later release could dislodge it.
# ~2.5h of job-tier downtime, ended only by deleting the pod by hand.
#
# These render the real template and assert the deadlock cannot recur, and that
# the guarantees the job tier actually depends on are still intact.
class TestJobStatefulSetPolicy < Minitest::Test
  include DevTestSupport

  K8S_DIR = File.expand_path('../k8s', __dir__)

  def self.rendered
    @rendered ||= begin
      env = {"APP" => "platform", "PORT" => "9300", "VERSION" => "0.0.0-test", "WEB_MEMORY" => "4400Mi"}
      out = IO.popen(env, ["pkl", "eval", "templates/scala-play-app.pkl"], chdir: K8S_DIR, &:read)
      raise "pkl eval failed" unless $?.success?
      out
    end
  end

  # The StatefulSet block, isolated so a Deployment-side match cannot pass.
  def job_statefulset
    docs = self.class.rendered.split(/^---$/)
    docs.find { |d| d =~ /kind: StatefulSet/ } or flunk("no StatefulSet in rendered manifest")
  end

  def test_job_statefulset_uses_parallel_pod_management
    assert_match(/podManagementPolicy: Parallel/, job_statefulset,
                 "OrderedReady makes a crashlooping pod permanently unupdatable: the " \
                 "controller never reaches the rolling update that would replace it, " \
                 "so no later release can recover the tier.")
  end

  def test_pod_name_is_still_a_single_stable_ordinal
    # The shutdown-then-start guarantee rests on name uniqueness, not on
    # podManagementPolicy: k8s cannot create platform-job-0 while the previous
    # platform-job-0 exists. That holds only while there is one ordinal.
    assert_match(/replicas: 1/, job_statefulset,
                 "Old and new job servers must never run concurrently. That is " \
                 "guaranteed by the pod NAME being reused, which holds for a single " \
                 "ordinal. More replicas would need the invariant re-derived.")
  end

  def test_stable_dns_identity_is_preserved
    # Why this is a StatefulSet at all: both tiers pin the job's DNS name in
    # JAVA_OPTS. A Deployment's random pod names would not resolve, so the
    # workload type is not free to change.
    assert_match(/platform-job-0\.platform-job/, self.class.rendered,
                 "deployment.nodes pins the stable hostname; it must survive any " \
                 "change to how job pods are managed.")
    assert_match(/serviceName: platform-job/, job_statefulset,
                 "The headless service backs that DNS name.")
  end

  # podManagementPolicy is immutable (verified against the live cluster:
  # "Forbidden: updates to statefulset spec for fields other than 'replicas',
  # 'ordinals', 'template', 'updateStrategy', ... are forbidden"). Without a
  # migration, changing the template would fail EVERY deploy of EVERY
  # scala-play app at the apply step.
  K8S_DEPLOY = File.read(File.expand_path('../bin/k8s-deploy', __dir__))

  def test_deploy_migrates_the_immutable_field_before_applying
    migrate = K8S_DEPLOY.index("adopt_statefulset_for_immutable_change(K8S_NAMESPACE")
    apply   = K8S_DEPLOY.index("kubectl apply -f #{'#'}{manifest_file} -l tier=job")
    refute_nil migrate, "The template change is unshippable without this migration."
    refute_nil apply
    assert migrate < apply,
           "The migration must precede the apply — the apply is the thing that " \
           "gets rejected."
  end

  def test_migration_orphans_pods_rather_than_deleting_them
    assert_match(/--cascade=orphan/, K8S_DEPLOY,
                 "A default cascading delete would tear down the running job pod " \
                 "for no reason. Orphaning keeps it alive; the recreated " \
                 "StatefulSet re-adopts it by label selector.")
  end

  def test_migration_is_skipped_when_the_policy_already_matches
    # Idempotence is what makes this safe to leave in the deploy path forever.
    assert_match(/return if live == desired/, K8S_DEPLOY,
                 "Must no-op once migrated, or every deploy would needlessly " \
                 "delete and recreate the StatefulSet.")
    assert_match(/return if live\.empty\?/, K8S_DEPLOY,
                 "A StatefulSet that does not exist yet is created correctly by " \
                 "the apply; there is nothing to migrate.")
  end

  def test_web_deployment_is_untouched
    web = self.class.rendered.split(/^---$/).find { |d| d =~ /kind: Deployment/ }
    refute_nil web
    refute_match(/podManagementPolicy/, web,
                 "podManagementPolicy is a StatefulSet field; it must not leak into " \
                 "the web Deployment.")
  end
end

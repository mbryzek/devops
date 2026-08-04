# Explains WHY a rollout did not finish, rather than only that it did not.
#
# There are two failures that look identical in `kubectl get pods` — a pod that
# is 0/1 and CrashLoopBackOff — and they need opposite responses:
#
#   1. The new image is broken. The pod IS running the tag you just deployed and
#      cannot start. Fix the code, cut a new tag.
#
#   2. The rollout is deadlocked. The pod is still running an OLD tag and never
#      received the new one. A StatefulSet with podManagementPolicy OrderedReady
#      will not delete a pod until it is Ready, so a pod that crashlooped on
#      release N is never updated by N+1, N+2, ... It sits there executing the
#      original broken image forever. Cutting new tags cannot fix it; the pod has
#      to be deleted.
#
# platform 0.18.83 shipped a malformed logback.xml and put platform-job-0 into
# (1). By 0.18.85 the code was fixed and the tier was in (2) — same pod, same
# CrashLoopBackOff, same log lines, but now for an entirely different reason, and
# two good releases in a row appeared to "fail" because of it.
module RolloutDiagnosis
  # pods: [{name:, image:, ready:}]
  def self.not_ready(pods)
    pods.reject { |p| p[:ready] }
  end

  # Pods that are not running the image the workload spec asks for. A pod can
  # only be in this state because the controller has not replaced it yet.
  def self.stale(pods, desired_image)
    pods.select { |p| p[:image] != desired_image }
  end

  # Returns a list of explanation lines, or [] when nothing conclusive is found.
  # Callers print these above the raw pod dump.
  def self.explain(workload:, desired_image:, pods:)
    broken = not_ready(pods)
    return [] if broken.empty?

    stuck = stale(broken, desired_image)

    if stuck.empty?
      [
        "#{workload}: running the deployed image (#{desired_image}) but not becoming ready.",
        "This is an application startup failure — see the pod logs below.",
      ]
    else
      names = stuck.map { |p| "#{p[:name]} on #{p[:image]}" }.join(", ")
      [
        "#{workload}: DEADLOCKED ROLLOUT — not an application failure.",
        "  spec wants: #{desired_image}",
        "  still running: #{names}",
        "",
        "These pods never received the new image. A StatefulSet will not delete a",
        "pod until it is Ready, so one that crashlooped on an earlier release is",
        "never updated by later ones. Deploying another tag will NOT fix this.",
        "",
        "Delete the pod(s) to break the deadlock; the controller recreates them",
        "on the current spec:",
      ] + stuck.map { |p| "  kubectl delete pod -n <namespace> #{p[:name]}" }
    end
  end
end

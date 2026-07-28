require 'json'
require 'fileutils'

# DigitalOcean accounts, keyed by a stable label (e.g. "personal", "playbook").
# Mirrors the Cloudflare pattern (env/cloudflare-accounts.pkl + release-sveltekit):
# the label -> account map lives in the env repo (digital-ocean-accounts.pkl), and each app
# names its account via `digital_ocean_account` in its config.pkl (default "personal").
#
# An account carries everything that is account-scoped on the DO side: the doctl
# auth context, the kube context of its cluster, the container registry, the k8s
# namespace, the region, and the bastion droplet used for database access.
#
# Activation pins both CLIs for the current process AND every child process:
#   - doctl: DIGITALOCEAN_CONTEXT selects the auth context.
#   - kubectl: KUBECONFIG gets a stub file prepended whose only job is to set
#     current-context (for single-value fields, the first file in KUBECONFIG
#     order wins in kubectl's merge), so the user's global current-context is
#     never mutated and parallel releases to different accounts cannot race
#     on a shared `kubectl config use-context`.
module DigitalOceanAccounts
  ACCOUNTS_PKL = File.expand_path(File.join(File.dirname(__FILE__), "../../env/digital-ocean-accounts.pkl"))
  STUB_DIR = File.expand_path("~/.devops/kubeconfig")

  # label -> account hash, memoized per path (path is injectable for tests).
  def DigitalOceanAccounts.all(path: ACCOUNTS_PKL)
    @all ||= {}
    @all[path] ||= begin
      unless File.exist?(path)
        Util.exit_with_error("#{path} not found (label -> DigitalOcean account map)")
      end
      json = `pkl eval -f json #{path}`
      Util.exit_with_error("Failed to evaluate #{path}") unless $?.success?
      JSON.parse(json)["accounts"]
    end
  end

  def DigitalOceanAccounts.for_label(label, path: ACCOUNTS_PKL)
    acct = DigitalOceanAccounts.all(path: path)[label]
    if acct.nil?
      Util.exit_with_error(
        "No entry for DigitalOcean account '#{label}' in #{path}. " \
        "Configured: #{DigitalOceanAccounts.all(path: path).keys.join(", ")}"
      )
    end
    acct
  end

  # Account for an App (lib/app.rb) via its digital_ocean_account label.
  def DigitalOceanAccounts.for_app(app_config)
    DigitalOceanAccounts.for_label(app_config.digital_ocean_account)
  end

  def DigitalOceanAccounts.for_app_name(app_name)
    DigitalOceanAccounts.for_app(Config.load(app_name))
  end

  # Pin doctl (and, unless require_kube is false, kubectl) to the account for
  # this process and all children. Returns the account hash.
  #
  # require_kube: false is for scripts that never touch the cluster (e.g.
  # k8s-build pushes an image but runs no kubectl) — they can operate against
  # an account whose cluster does not exist yet.
  def DigitalOceanAccounts.activate!(label, require_kube: true)
    acct = DigitalOceanAccounts.for_label(label)
    ENV['DIGITALOCEAN_CONTEXT'] = acct['doctl_context']

    kube = acct['kube_context']
    if kube.nil? || kube.to_s.strip.empty?
      if require_kube
        Util.exit_with_error(
          "DigitalOcean account '#{label}' has no kube_context configured in " \
          "#{ACCOUNTS_PKL} — is its cluster provisioned yet?"
        )
      end
      Util.detail("DigitalOcean account: #{label} (doctl context #{acct['doctl_context']}; no kube context)")
      return acct
    end

    base = ENV['KUBECONFIG'].to_s.empty? ? File.expand_path("~/.kube/config") : ENV['KUBECONFIG']
    # Never stack stubs: strip any previously activated stub so switching
    # accounts within one process replaces the pinned context instead of
    # leaving the first stub's current-context in front.
    base = base.split(":").reject { |p| p.start_with?("#{STUB_DIR}#{File::SEPARATOR}") }.join(":")
    ENV['KUBECONFIG'] = "#{DigitalOceanAccounts.kube_context_stub(label, kube)}:#{base}"
    Util.detail("DigitalOcean account: #{label} (doctl context #{acct['doctl_context']}, kube context #{kube})")
    acct
  end

  def DigitalOceanAccounts.activate_for_app!(app_config, require_kube: true)
    DigitalOceanAccounts.activate!(app_config.digital_ocean_account, require_kube: require_kube)
  end

  # A minimal kubeconfig whose only content is current-context. Prepended to
  # KUBECONFIG it selects the context without editing the real config.
  def DigitalOceanAccounts.stub_content(kube_context)
    "apiVersion: v1\nkind: Config\ncurrent-context: #{kube_context}\n"
  end

  def DigitalOceanAccounts.kube_context_stub(label, kube_context)
    FileUtils.mkdir_p(STUB_DIR)
    path = File.join(STUB_DIR, "#{label}.yaml")
    File.write(path, DigitalOceanAccounts.stub_content(kube_context))
    path
  end
end

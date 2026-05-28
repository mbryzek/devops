require 'json'
require 'fileutils'
require 'shellwords'

# Cross-repo lock of the API Builder version each application was last published at.
#
# A producer repo (the one that owns + uploads a spec) records the immutable
# version its upload created; a consumer repo (which only codegens against that
# spec) reads the lock and pins its codegen to that exact version, so a concurrent
# upload by another session moving `latest` can't make the consumer codegen the
# wrong version. Default (no lock entry) leaves codegen on `latest`.
#
# The lock lives at the *feature root* — the parent of the git repo, where sibling
# repo clones live — so the producer run (in one repo) and the consumer run (in a
# sibling repo) share it. Override the location with APIBUILDER_VERSION_LOCK.
module VersionLock

  RELATIVE_PATH = File.join(".apibuilder", "versions.lock").freeze

  def self.key(org, app)
    "#{org}/#{app}"
  end

  def self.path(project_root)
    override = ENV["APIBUILDER_VERSION_LOCK"]
    return override if override && !override.empty?
    File.join(feature_root(project_root), RELATIVE_PATH)
  end

  # Parent of the git repo root (the feature dir holding sibling clones). Falls back
  # to the parent of project_root when not inside a git repo.
  def self.feature_root(project_root)
    toplevel = `git -C #{Shellwords.escape(project_root)} rev-parse --show-toplevel 2>/dev/null`.strip
    base = toplevel.empty? ? project_root : toplevel
    File.dirname(File.expand_path(base))
  end

  # Returns { "org/app" => version } (empty if no lock yet / unreadable / wrong shape).
  def self.read(project_root)
    p = path(project_root)
    return {} unless File.exist?(p)
    parsed = JSON.parse(IO.read(p))
    parsed.is_a?(Hash) ? parsed : {}
  rescue JSON::ParserError
    {}
  end

  # Merge the given { "org/app" => version } into the lock and persist it. No-op for
  # an empty map. Returns the lock path written (or nil).
  def self.write(project_root, versions_by_key)
    return nil if versions_by_key.empty?
    p = path(project_root)
    merged = read(project_root).merge(versions_by_key)
    FileUtils.mkdir_p(File.dirname(p))
    IO.write(p, JSON.pretty_generate(merged) + "\n")
    p
  end

end

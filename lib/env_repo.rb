# The git-crypt'd secrets repo beside this checkout: where it is, how to tell a
# locked file from a readable one, and how to read a whole-file secret out of it
# WITHOUT unlocking anything.
#
# Two facts used to be stated only inside EnvironmentVariables, which reads one
# layout in that repo — `apps/<app>/env/<environment>.env`, a file of KEY=VALUE
# lines. `api_keys/<name>` is a second layout in the same repo: one credential
# per file, the whole file IS the value, and it is where the credentials a HUMAN
# or a tool authenticates with live (`linear`, `newrelic`, `pbvision`) as
# distinct from the ones an app boots with. Both need the same two facts, so
# they are said here once rather than copied.
#
# NOTHING HERE UNLOCKS. `EnvironmentVariables.from_file` runs git-crypt unlock on
# the way past because it is release tooling driven by a human at a terminal;
# every reader here is answering "is this secret readable" for the agent, which
# is forbidden from unlocking the repo at all. A locked file is therefore a state
# this REPORTS, never one it fixes.
module EnvRepo
  DIR = File.dirname(__FILE__)

  # git-crypt writes this magic at the head of every encrypted blob, so a file
  # starting with it is present-but-locked rather than corrupt.
  GITCRYPT_HEADER = "\x00GITCRYPT".freeze

  # The env repo is a SIBLING of this devops checkout, resolved relative to this
  # file rather than to $HOME. That is what makes a devops clone inside a feature
  # dir resolve to a path that does not exist — reported as :no_file below, and
  # deliberately not the same answer as "the secret is not set".
  def self.root
    File.join(DIR, "../../env")
  end

  def self.path(relative)
    File.join(root, relative)
  end

  def self.locked?(path)
    File.binread(path, GITCRYPT_HEADER.bytesize).to_s.start_with?(GITCRYPT_HEADER)
  end

  # One whole-file secret. Returns [:present, value], [:missing, nil] (the file
  # is there and empty, which is a different mistake from it being absent),
  # [:locked, nil] or [:no_file, nil] — the same four states
  # `EnvironmentVariables.lookup` answers with, so a caller can treat the two
  # layouts uniformly.
  def self.read_secret(relative)
    file = path(relative)
    return [:no_file, nil] unless File.exist?(file)
    return [:locked, nil] if locked?(file)

    value = File.read(file).strip
    value.empty? ? [:missing, nil] : [:present, value]
  end
end

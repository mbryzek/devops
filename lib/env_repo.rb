# The git-crypt'd secrets repo beside this checkout: where it is, how to tell a
# locked file from a readable one, and how to read a whole-file secret out of it
# WITHOUT unlocking anything.
#
# Two facts used to be stated only inside EnvironmentVariables, which reads one
# layout in that repo — `apps/<app>/env/<environment>.env`, a file of KEY=VALUE
# lines. `api_keys/<name>` is a second layout in the same repo: it is where the
# credentials a HUMAN or a tool authenticates with live (`linear`, `newrelic`,
# `pbvision`) as distinct from the ones an app boots with. Both need the same two
# facts, so they are said here once rather than copied.
#
# An api_keys file is read one of two ways, and which one is a property of the
# SERVICE rather than a style choice. Most services authenticate with a single
# opaque string, so the whole file IS the value (`read_secret`). Some
# authenticate with a TUPLE — Court Reserve wants an email and a password — and
# for those the file carries KEY=VALUE lines and each variable is read out by
# name (`read_var`). The tuple case is not two files, because half a login is
# not a credential: provisioning has to be one file that is either there or not.
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

  # One KEY=VALUE variable out of one file, over the same four states, for the
  # services whose credential is a tuple rather than a single string.
  #
  # :missing covers both "the file has no such line" and "the line is there and
  # empty", which is the same conflation `read_secret` makes for an empty file
  # and for the same reason: both are somebody having written the file and not
  # finished the job, and the remedy printed for them is identical.
  def self.read_var(relative, key)
    file = path(relative)
    return [:no_file, nil] unless File.exist?(file)
    return [:locked, nil] if locked?(file)

    value = parse_var(File.read(file), key)
    value.nil? ? [:missing, nil] : [:present, value]
  end

  # The KEY=VALUE parser both layouts share — `api_keys/<service>` here and
  # `apps/<app>/env/<environment>.env` in EnvironmentVariables.lookup, which
  # calls this rather than keeping a second copy that could drift on the one
  # thing that matters: `split("=", 2)`, so a password containing `=` survives.
  #
  # nil rather than "" for a key that is absent OR empty, so a caller scanning
  # several files (lookup does) falls through to the next one on both.
  def self.parse_var(contents, key)
    contents.each_line do |line|
      k, v = line.strip.split("=", 2)
      next unless k.to_s.strip == key

      value = v.to_s.strip
      return value unless value.empty?
    end
    nil
  end
end

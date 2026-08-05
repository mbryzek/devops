require 'fileutils'
require 'shellwords'

# A checkout of an app's schema repo that the TOOLING owns and keeps at
# origin/main.
#
# `claude-db sync` applies the migration scripts it finds in a checkout, so the
# database it produces is only ever as current as that checkout. When the caller
# has a schema clone of their own — they are standing in it, it sits next to
# their feature dir, or they named it with --repo-dir — that is the right one to
# use, migrations in progress and all.
#
# The problem is the case where they have none. `DbApp.resolve` then falls back
# to ~/code/<app>-postgresql, which belongs to nobody in particular and is
# pulled only when a human happens to pull it. On the agent runner it is nobody:
# an autonomous session may not write outside its workspace, so no session can
# update that checkout and every session inherits whatever state it is in,
# drifting further each day. On 2026-08-05 it was 20 commits and 12 migrations
# behind, which arrived as eight failing tests that looked like the branch's
# fault (ISS-545).
#
# So the fallback stops being a human's tree and becomes this: a clone under
# ~/code/ai/, beside the port history file, fetched and hard-reset to
# origin/main on every use. Nothing writes to it and nothing is developed in it,
# which is what makes resetting it safe — and what makes it a cache rather than
# a checkout. Failure to refresh it is never fatal: an existing mirror is used
# as it stands, and with no mirror at all the caller keeps the checkout they
# would have had anyway.
module SchemaMirror
  # ~/code/ai is the shared root every session works under and already holds
  # .claude-db-ports.json, so it is where the session-DB tooling keeps state
  # both a human and an agent can reach. Dotted so it is not mistaken for a
  # feature directory by anything that lists ~/code/ai.
  ROOT = File.expand_path("~/code/ai/.claude-db-schema")

  SUFFIX = "-postgresql".freeze

  def SchemaMirror.path(base, root: ROOT)
    File.join(root, "#{base}#{SUFFIX}")
  end

  # A checkout of <base>-postgresql pinned at origin/main, or nil when one
  # cannot be produced. `origin_from` is an existing checkout to read the remote
  # url out of — whichever transport (ssh or https) it uses is the one already
  # known to work on this box, so the url is taken from there rather than
  # assembled from a hardcoded org name.
  def SchemaMirror.checkout(base, origin_from:, root: ROOT)
    dir = SchemaMirror.path(base, :root => root)
    FileUtils.mkdir_p(root)

    SchemaMirror.locked(base, root) do
      if SchemaMirror.git_repo?(dir)
        next dir if SchemaMirror.pin_to_origin_main(dir)
        # Offline, or origin unreachable. A mirror that was pinned to main the
        # last time it was reachable is still the best checkout available —
        # certainly better than the one nobody can pull. Use it as it stands.
        next SchemaMirror.usable?(dir) ? dir : nil
      end

      url = SchemaMirror.origin_url(origin_from)
      next nil if url.nil?
      next nil unless SchemaMirror.git("clone", "--quiet", url, dir)
      SchemaMirror.pin_to_origin_main(dir) && SchemaMirror.usable?(dir) ? dir : nil
    end
  end

  # Fetch and hard-reset to origin/main. True when the mirror now matches main.
  #
  # `clean` matters as much as `reset`: an untracked .sql left in scripts/ —
  # from an interrupted clone, or a stray copy — would be handed to sem-apply as
  # if it were a released migration.
  def SchemaMirror.pin_to_origin_main(dir)
    return false unless SchemaMirror.git("fetch", "--quiet", "origin", :chdir => dir)
    SchemaMirror.git("reset", "--quiet", "--hard", "origin/main", :chdir => dir) &&
      SchemaMirror.git("clean", "-qfd", :chdir => dir)
  end

  def SchemaMirror.git_repo?(dir)
    File.directory?(File.join(dir, ".git"))
  end

  # A mirror is only worth handing back if it actually holds migration scripts:
  # an empty or half-cloned directory would sync a database to nothing and
  # report it as up to date.
  def SchemaMirror.usable?(dir)
    Dir.exist?(File.join(dir, "scripts")) &&
      !Dir[File.join(dir, "scripts", "*.sql")].empty?
  end

  def SchemaMirror.origin_url(checkout)
    return nil unless checkout && SchemaMirror.git_repo?(checkout)
    url = `git -C #{Shellwords.shellescape(checkout)} remote get-url origin 2>/dev/null`.strip
    url.empty? ? nil : url
  end

  def SchemaMirror.git(*args, chdir: nil)
    opts = { :out => File::NULL, :err => File::NULL }
    opts[:chdir] = chdir if chdir
    system("git", *args, **opts)
  end

  # Serialise refreshes across concurrent sessions.
  #
  # SEM scripts are append-only (filenames are timestamps and a released script
  # is never edited), so a refresh can only ADD files to the mirror — a reader
  # racing one sees a prefix of main's scripts, never a reordered or truncated
  # history. The lock exists for the git operations themselves, which do not
  # tolerate two processes resetting the same working tree at once.
  def SchemaMirror.locked(base, root)
    lock = File.join(root, ".#{base}.lock")
    File.open(lock, File::CREAT | File::RDWR, 0o644) do |f|
      f.flock(File::LOCK_EX)
      yield
    end
  end
end

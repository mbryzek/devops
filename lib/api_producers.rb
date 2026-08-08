require 'open3'

# Spec resolution source #3: the producer checkouts under ~/code.
#
# Every apibuilder spec is owned by one of three repos. A consumer checkout
# (playbook-app, acumen-ui, hoa-frontend, ...) has none of them, so before this
# existed a bare `api` there resolved every spec from the registry — which means
# RELEASED, not merged — and said nothing about it. On 2026-08-04 that produced
# 167 svelte-check errors on a clean playbook-app main, diagnosable only by
# noticing src/generated/ was the sole dirty path.
#
# So `api` reads the producers directly, out of ~/code/<repo> at origin/main, via
# `git show` — NEVER the working tree. ~/code/platform is Mike's own checkout and
# is routinely dirty and on a feature branch; reading through git is what keeps
# work in progress from leaking silently into a consumer's regen. A producer that
# IS the current repo (or a sibling clone in the same ~/code/ai/<feature>/ dir) is
# excluded entirely — that session's working tree wins for all of its specs, so a
# repo is never half-resolved from its own branch and half from origin/main.
#
# Specs are indexed by FILE NAME (`spec/foo.json` => app key `foo`), which is why
# those names must be globally unique across the three producers: two files with
# the same name means an ambiguous source, and this refuses to guess.
class ApiProducers

  # Hardcoded, deliberately. There are three spec producers; a discovery
  # mechanism would be more machinery than the fact it discovers. Adding a
  # fourth producer means adding it here (and keeping spec file names unique).
  REPOS = %w[platform acumen lib-ai].freeze

  # Read from the merged remote branch, never a local branch and never the
  # working tree. `latest` in the registry means released; this means merged.
  REF = "origin/main".freeze

  CODE_ROOT = File.expand_path("~/code").freeze

  # `spec/x.json` and `dao/spec/x.json`, at any depth.
  SPEC_PATH_RE = %r{(?:\A|/)spec/[^/]+\.json\z}.freeze

  # Set to skip the `git fetch` refresh (offline, or a test that must not touch
  # the network). Resolution then uses whatever origin/main the checkout has.
  SKIP_FETCH_ENV = "API_SKIP_PRODUCER_FETCH".freeze

  FETCH_TIMEOUT_SECONDS = 20

  # Reads a single path out of a git ref. Returns nil when the path is absent at
  # that ref, which is the normal answer for a spec that only exists on a branch.
  def self.show(dir, ref, path)
    out, status = Open3.capture2("git", "-C", dir, "show", "#{ref}:#{path}", err: File::NULL)
    status.success? ? out : nil
  end

  # Reads MANY paths out of one git ref, in a single `git cat-file --batch`.
  # Returns {path => contents}, omitting paths absent at that ref.
  #
  # `show` per path is one process per file, and the importer scan reads every spec
  # a producer has: 106 in platform alone, ~3.5s of pure fork/exec on this fleet.
  # This is the same read in ~0.1s. Requests are written and answers read one at a
  # time — `cat-file --batch` flushes per request, and interleaving is what keeps a
  # large path list from deadlocking on a full pipe buffer.
  def self.show_many(dir, ref, paths)
    return {} if paths.empty?

    contents = {}
    Open3.popen2("git", "-C", dir, "cat-file", "--batch", err: File::NULL) do |stdin, stdout, wait_thr|
      stdin.binmode
      stdout.binmode
      begin
        paths.each do |path|
          stdin.puts("#{ref}:#{path}")
          stdin.flush
          header = stdout.gets or break
          # "<oid> <type> <size>" for a hit; "<request> missing" (or "ambiguous") otherwise.
          _oid, type, size = header.chomp.split(" ")
          next if size.nil?
          # Read the body even for a non-blob: leaving it in the pipe would desync
          # every answer after it, which is a silent wrong answer rather than a miss.
          body = stdout.read(size.to_i)
          stdout.read(1) # the newline git writes after every object
          contents[path] = body.force_encoding(Encoding::UTF_8) if type == "blob"
        end
      ensure
        stdin.close unless stdin.closed?
        wait_thr.value
      end
    end
    contents
  end

  # exclude: repo names whose specs this session already has locally (this repo
  # and any sibling clones), which must not be second-guessed from origin/main.
  def initialize(exclude: [], code_root: CODE_ROOT, ref: REF, repos: REPOS)
    excluded = Array(exclude).map(&:to_s)
    @repos = repos.reject { |r| excluded.include?(r) }
    @code_root = code_root
    @ref = ref
    @index = nil
  end

  # Source hash for [org, app_key], or nil. Matched on the app key alone: file
  # names are unique across producers (enforced in build_index), so the org
  # cannot disambiguate anything the file name does not.
  def [](key)
    index[Array(key).last]
  end

  def app_keys
    index.keys
  end

  # Test seam: a process that has already indexed a set of producers must not
  # fetch and re-read them for a second codegen root (a repo with nestedConfigs
  # builds one chain per root).
  def self.reset_cache!
    @cache = nil
  end

  def self.cache
    @cache ||= {}
  end

  private

  def index
    @index ||= self.class.cache[[@code_root, @ref, @repos]] ||= build_index
  end

  def build_index
    dirs = @repos.filter_map do |repo|
      dir = File.join(@code_root, repo)
      [repo, dir] if File.directory?(File.join(dir, ".git"))
    end
    return {} if dirs.empty?

    fetch_all(dirs)

    entries = {}
    sources_by_key = Hash.new { |h, k| h[k] = [] }
    dirs.each do |repo, dir|
      description = ref_description(dir)
      if description.nil?
        Util.warning("Skipping producer #{repo}: #{@ref} not found in #{dir} (fetch it once to enable)")
        next
      end
      label = "~/code/#{repo}@#{@ref} (#{description})"
      spec_paths(dir).each do |path|
        app_key = File.basename(path, ".json")
        sources_by_key[app_key] << "#{repo}/#{path}"
        entries[app_key] = { git: true, repo: repo, dir: dir, ref: @ref, path: path, label: label }
      end
    end

    ambiguous = sources_by_key.select { |_key, paths| paths.size > 1 }
    if ambiguous.any?
      details = ambiguous.sort.map { |key, paths| "  #{key}: #{paths.sort.join(', ')}" }.join("\n")
      Util.exit_with_error(
        "Ambiguous spec file name(s) across producers — spec file names must be globally\n" \
        "unique across #{@repos.join(', ')}, because that name IS the application key:\n" \
        "#{details}\n" \
        "Rename one of each pair (spec file, its application key, and every import URI\n" \
        "referencing it) so a name identifies exactly one source."
      )
    end

    entries
  end

  def spec_paths(dir)
    out, status = Open3.capture2("git", "-C", dir, "ls-tree", "-r", "--name-only", @ref, err: File::NULL)
    return [] unless status.success?
    out.lines.map(&:chomp).select { |path| SPEC_PATH_RE.match?(path) }
  end

  # Short sha + relative age, so the announcement says not just WHICH source but
  # how stale it is: "a1b2c3d, 3 weeks ago" is the tell that a fetch failed.
  def ref_description(dir)
    out, status = Open3.capture2("git", "-C", dir, "show", "-s", "--format=%h, %cr", @ref, err: File::NULL)
    status.success? && !out.strip.empty? ? out.strip : nil
  end

  # Refreshes origin/main in each producer checkout, in parallel. Fetch only
  # moves remote-tracking refs — it never touches the checkout's branch, index,
  # or working tree, so it is safe to run against Mike's own ~/code clones.
  # A failure (offline, auth) is a warning: resolution continues against the
  # origin/main already on disk, whose age the announcement prints.
  def fetch_all(dirs)
    return if ENV[SKIP_FETCH_ENV].to_s == "1"
    dirs.map do |repo, dir|
      Thread.new do
        _, err, status = Open3.capture3(
          "git", "-C", dir, "fetch", "--quiet", "origin", @ref.split("/").last
        )
        Util.warning("Could not fetch #{repo}: #{err.strip.lines.first}") unless status.success?
      end
    end.each { |t| t.join(FETCH_TIMEOUT_SECONDS) }
  end

end

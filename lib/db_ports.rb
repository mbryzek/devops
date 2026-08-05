require 'fileutils'
require 'json'
require 'set'
require 'socket'
require 'time'

# Host-port allocation for the per-schema-tag platformdb containers.
#
# There is one container per schema tag and one host port per container, so
# ports have to be handed out rather than hardcoded. Allocations are recorded in
# a shared history file so that parallel Claude sessions — which cannot see each
# other's shells — do not hand out the same port twice.
#
# The file lives in ~/code/ai deliberately: that is the shared root every
# session works under, so it is the one place all of them can agree on.
#
# Everything in here that does arithmetic is a pure function taking its inputs
# explicitly (`next_free_port`, `taken_ports`), so the wrap and exhaustion paths
# are testable without a Docker daemon, a listening socket, or the real history
# file.
module DbPorts
  # Inclusive range for session containers. Deliberately clear of 5432 (Mike's
  # Postgres.app), 5433 (the legacy pre-split container), and 5454
  # (_prepare-schema.sh's scratch container).
  RANGE_MIN = 5500
  RANGE_MAX = 9999

  HISTORY_PATH = File.expand_path("~/code/ai/.claude-db-ports.json")

  HOST = "127.0.0.1"

  # ── history file ──────────────────────────────────────────────────────────
  #
  # Shape:
  #   {
  #     "last_issued": 5501,
  #     "allocations": [
  #       {
  #         "port": 5500,
  #         "schema_tag": "0.5.22",
  #         "container": "platformdb-claude-0.5.22",
  #         "session_id": "db-per-tag",
  #         "allocated_at": "2026-07-29T12:34:56Z"
  #       }
  #     ]
  #   }
  #
  # `last_issued` is what makes the sequence correct AFTER a wrap: once the
  # allocator has wrapped past 9999 back to 5500, "highest port recorded + 1" is
  # 10000 — out of range — and would either fail or restart the scan from the
  # bottom every time. Scanning forward from last_issued keeps it monotonic
  # within a lap and terminating across laps.
  # Serialise the read-compute-write on the history file across concurrent
  # sessions.
  #
  # The file exists so that parallel sessions do not hand out the same port
  # twice, and until this lock it did not actually deliver that: `allocate!` and
  # `record` both load, compute and save with nothing holding the file in
  # between, so two `claude-db start`/`next-port` calls landing in the same
  # window read the same `last_issued`, computed the same candidate, and both
  # wrote it back. The `bound` probe does not close the gap either -- TCPServer
  # is opened and closed to test the port, not held.
  #
  # Same shape as SchemaMirror.locked, which serialises the other piece of
  # shared state under ~/code/ai for exactly the same reason.
  #
  # NOT re-entrant: flock is per open file description, so a second `locked`
  # inside a first would deadlock in the same process. `allocate!` and `record`
  # are both called at the top level from bin/claude-db and neither calls the
  # other -- keep it that way.
  def DbPorts.locked(path = HISTORY_PATH)
    FileUtils.mkdir_p(File.dirname(path)) unless File.directory?(File.dirname(path))
    File.open("#{path}.lock", File::CREAT | File::RDWR, 0o644) do |f|
      f.flock(File::LOCK_EX)
      yield
    end
  end

  def DbPorts.load_history(path = HISTORY_PATH)
    return empty_history unless File.exist?(path)
    raw = JSON.parse(File.read(path))
    return empty_history unless raw.is_a?(Hash)
    {
      "last_issued" => (raw["last_issued"].to_i if raw["last_issued"]),
      "allocations" => (raw["allocations"].is_a?(Array) ? raw["allocations"] : [])
    }
  rescue JSON::ParserError
    # A corrupt history file must not wedge every session. Treat it as empty:
    # the liveness checks below (container exists / port bound) are what actually
    # keep an occupied port from being handed out, and they do not depend on it.
    warn "claude-db: #{path} is not valid JSON — treating the port history as empty"
    empty_history
  end

  def DbPorts.empty_history
    { "last_issued" => nil, "allocations" => [] }
  end

  def DbPorts.save_history(history, path = HISTORY_PATH)
    FileUtils.mkdir_p(File.dirname(path)) unless File.directory?(File.dirname(path))
    File.write(path, JSON.pretty_generate(history) + "\n")
    history
  end

  # Record that `port` was issued for `container`, and remember it as the point
  # the next scan starts from.
  def DbPorts.record(port:, schema_tag:, container:, session_id:, path: HISTORY_PATH, now: Time.now)
    locked(path) do
      history = load_history(path)
      history["allocations"] << {
        "port" => port,
        "schema_tag" => schema_tag,
        "container" => container,
        "session_id" => session_id,
        "allocated_at" => now.utc.strftime("%Y-%m-%dT%H:%M:%SZ")
      }
      history["last_issued"] = port
      save_history(history, path)
    end
  end

  # Forget every allocation for `container` (its container is gone). Ports are
  # freed for reuse; `last_issued` is left alone so the sequence keeps moving
  # forward rather than immediately recycling a just-released port.
  def DbPorts.release_container(container, path: HISTORY_PATH)
    locked(path) do
      history = load_history(path)
      before = history["allocations"].length
      history["allocations"] = history["allocations"].reject { |a| a["container"] == container }
      released = before - history["allocations"].length
      save_history(history, path) if released > 0
      released
    end
  end

  # ── liveness ──────────────────────────────────────────────────────────────

  # True when something is listening on `port` on this host.
  #
  # Bind test rather than connect test: a bind fails for a port held by a
  # process that is not accepting connections yet (a container mid-boot), which
  # a connect test would call free. Reuseaddr is deliberately NOT set — the
  # question is "can a container publish here", and Docker's bind is the real
  # arbiter.
  def DbPorts.port_bound?(port)
    server = TCPServer.new(HOST, port)
    server.close
    false
  rescue Errno::EADDRINUSE, Errno::EACCES
    true
  rescue StandardError
    # Anything unexpected counts as taken. Handing out a port we could not prove
    # free is the expensive mistake; skipping one we could have used is not.
    true
  end

  def DbPorts.port_in_range?(port)
    port.is_a?(Integer) && port >= RANGE_MIN && port <= RANGE_MAX
  end

  # Next free port, scanning forward from `last_issued` and wrapping at RANGE_MAX.
  #
  # PURE: `taken` is a set of ports reserved by history, and `bound` answers "is
  # this port bound on the host right now" — injected so the wrap, the skip, and
  # the exhaustion paths are all testable without touching Docker or a socket.
  #
  # Returns nil when every port in the range is taken.
  def DbPorts.next_free_port(last_issued:, taken:, bound: nil)
    bound ||= ->(port) { port_bound?(port) }
    span = RANGE_MAX - RANGE_MIN + 1

    start = if last_issued.nil? || !port_in_range?(last_issued.to_i)
              # No usable history: start at the bottom of the range.
              RANGE_MIN
            elsif last_issued.to_i == RANGE_MAX
              RANGE_MIN            # wrap
            else
              last_issued.to_i + 1
            end

    offset = start - RANGE_MIN
    span.times do |i|
      candidate = RANGE_MIN + ((offset + i) % span)
      next if taken.include?(candidate)
      next if bound.call(candidate)
      return candidate
    end
    nil
  end

  # Ports reserved by history: recorded for a container that STILL EXISTS.
  #
  # Both this and the bind test matter, and neither subsumes the other:
  #   - reserved here — the container may be STOPPED, so nothing is bound, but
  #     the port is still spoken for and `start` may bring it back up
  #   - bound on the host — covers containers this history never saw (the legacy
  #     container, an unrelated service) and history entries that under-report
  #
  # A history entry whose container is GONE is deliberately NOT reserved: that
  # is the stale-entry case, and holding those forever would leak the range. The
  # bind test is the backstop that keeps a stale entry from handing out a port
  # something is actually listening on.
  def DbPorts.reserved_ports(history, container_exists:)
    (history["allocations"] || [])
      .select { |a| container_exists.call(a["container"]) }
      .map { |a| a["port"].to_i }
      .select { |p| port_in_range?(p) }
      .to_set
  end

  # Allocate the next port and persist it as last_issued, so two concurrent
  # `next-port` calls cannot both be told the same number. Returns the port, or
  # nil when the range is exhausted.
  #
  # Persisting on ISSUE rather than on use means an unused answer burns a port
  # number. That is intentional and harmless: the number is reclaimed on the
  # next lap, and the alternative — handing the same port to two sessions
  # racing to `start` — is not.
  def DbPorts.allocate!(path: HISTORY_PATH, container_exists: nil, bound: nil)
    container_exists ||= ->(name) { DbImages.container_exists?(name.to_s) }
    locked(path) do
      history = load_history(path)
      taken = reserved_ports(history, :container_exists => container_exists)
      port = next_free_port(:last_issued => history["last_issued"], :taken => taken, :bound => bound)
      next nil if port.nil?
      history["last_issued"] = port
      save_history(history, path)
      port
    end
  end
end

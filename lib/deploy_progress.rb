require 'io/console'
require 'util'

# Live phase display for `dev deploy`.
#
# Every release script already narrates itself through Util.step, which prints
# exactly one line per stage in quiet mode:
#
#     Building Docker image... done (15s)
#
# The label half is written (and flushed) when the stage STARTS and the
# "done (15s)" half when it ends, so a parent reading the subprocess pipe can
# see both "which stage is running right now" and "how long each finished one
# took". That is the whole event stream this class renders — there is no
# separate marker protocol to keep in sync, and `tail -f` on the deploy log
# still shows the same human-readable lines.
#
# Rendering has two modes:
#
#   TTY      one live block, redrawn in place once a second, holding only the
#            apps still running. A finished app is flushed permanently above
#            the block as a single collapsed line, so the block stays as short
#            as the work still outstanding.
#
#   non-TTY  append-on-change only (pipes, cron, `dev deploy | tee`). No cursor
#            movement, no repeated frames — one line per actual event, prefixed
#            with the app name since interleaved concurrent output has no other
#            way to say who it belongs to.
#
# Thread-safe: the concurrent app phase feeds this from one worker thread per
# app, and the ticker redraws from another.
class DeployProgress
  INDENT = "  ".freeze
  PHASE_INDENT = "      ".freeze
  TICK_SECONDS = 1
  DEFAULT_WIDTH = 80
  MIN_PLAUSIBLE_WIDTH = 20

  # "Building Docker image... " — a stage that has started but not finished.
  # Only ever matched against a PARTIAL line (no newline seen yet), which is
  # precisely the state Util.step leaves the stream in while the block runs.
  PARTIAL_RE = /\A(.+?)\.\.\. \z/.freeze

  # "Building Docker image... done (15s)" / "... failed (8s)"
  COMPLETE_RE = /\A(.+?)\.\.\. (done|failed) \(([^)]*)\)\z/.freeze

  # release-scala / release-docker-k8s both end with this line. It is the only
  # reliable source for the version actually released: `dev deploy` knows the
  # CURRENT tag, but a release with unreleased commits mints a new one.
  VERSION_RE = /\ARelease complete: \S+ (\S+)\z/.freeze

  Phase = Struct.new(:label, :started_at, :outcome, :text, keyword_init: true)

  class AppState
    attr_accessor :name, :phases, :current, :version, :started_at, :buffer

    def initialize(name)
      @name = name
      @phases = []
      @current = nil
      @version = nil
      @started_at = Time.now
      # Binary: fed from raw pipe reads, whose chunk boundaries fall wherever
      # the kernel put them — including the middle of a multi-byte character.
      # Lines are decoded on the way out of here, once they're whole.
      @buffer = +"".b
    end

    def elapsed
      Time.now - @started_at
    end
  end

  # Stands in for a DeployProgress when the display must not be used at all —
  # the library phase inherits the terminal (release-lib prompts for a GPG
  # passphrase), so nothing may be drawing over it.
  class Disabled
    def start(_app); end
    def feed(_app, _chunk); end
    def finish(_app, ok:, version: nil); end
    def message(text) = puts(text)
    def run = yield(self)
  end

  def self.for(io = $stdout)
    new(io: io)
  end

  def initialize(io: $stdout)
    @io = io
    @tty = io.respond_to?(:tty?) && io.tty?
    @apps = {}
    @order = []
    @mutex = Mutex.new
    @lines_drawn = 0
    @ticker = nil
  end

  # Runs the block with the live display active, guaranteeing the terminal is
  # left clean (block erased, cursor at column 0) however the block exits.
  def run
    @ticker = Thread.new do
      loop do
        sleep TICK_SECONDS
        @mutex.synchronize { redraw }
      end
    end
    yield self
  ensure
    @ticker&.kill
    @mutex.synchronize { clear_block }
  end

  def start(app)
    @mutex.synchronize do
      @apps[app] = AppState.new(app)
      @order << app unless @order.include?(app)
      emit("#{INDENT}#{app} starting") unless @tty
      redraw
    end
  end

  # Feed raw bytes from the release subprocess. Chunks, not lines: a stage that
  # has started but not finished is a line with no newline on it yet, and
  # `each_line` would withhold it until the stage was already over — which is
  # exactly the interval the display exists to narrate.
  def feed(app, chunk)
    @mutex.synchronize do
      st = @apps[app] or next
      st.buffer << chunk.to_s.b
      while (i = st.buffer.index("\n"))
        line = st.buffer.slice!(0..i).chomp
        handle_line(st, Util.to_utf8(line))
      end
      handle_partial(st, Util.to_utf8(st.buffer))
      redraw
    end
  end

  # Collapse the app to its final one-line summary, flushed permanently above
  # the live block. On failure the phase list is kept: WHICH stage died, and
  # how long it got before dying, is the whole diagnostic.
  def finish(app, ok:, version: nil)
    @mutex.synchronize do
      st = @apps.delete(app)
      @order.delete(app)
      next if st.nil?

      st.version ||= version
      # A stage still open when the process exits never printed its own
      # completion half — close it out so it does not render as running forever.
      if st.current
        st.phases << Phase.new(label: st.current.label, outcome: ok ? "done" : "failed",
                               text: duration(Time.now - st.current.started_at))
        st.current = nil
      end

      clear_block
      emit("#{INDENT}#{app}  #{ok ? released_label(st) : 'FAILED'} (#{duration(st.elapsed)})")
      # Recap where a failure got to, UNDER its own header: with concurrent
      # apps finishing into one stream, a phase list printed above the line it
      # belongs to reads as belonging to the app that finished before it.
      # TTY only — the live block that held these lines is erased on the way
      # out, so without the recap they vanish. In append mode each one was
      # already printed, prefixed with the app name, as it happened.
      if !ok && @tty
        st.phases.each { |p| emit("#{PHASE_INDENT}#{p.label}... #{p.outcome} (#{p.text})") }
      end
      redraw
    end
  end

  # Print a line above the live block (phase banners, blank separators).
  def message(text)
    @mutex.synchronize do
      clear_block
      emit(text)
      redraw
    end
  end

  private

  def released_label(st)
    st.version ? "deployed #{st.version}" : "released"
  end

  def handle_partial(st, partial)
    md = PARTIAL_RE.match(partial) or return
    label = md[1]
    return if st.current&.label == label

    st.current = Phase.new(label: label, started_at: Time.now)
  end

  def handle_line(st, line)
    if (md = COMPLETE_RE.match(line))
      st.phases << Phase.new(label: md[1], outcome: md[2], text: md[3])
      st.current = nil
      emit("#{INDENT}#{st.name}  #{md[1]}... #{md[2]} (#{md[3]})") unless @tty
    elsif (md = VERSION_RE.match(line))
      st.version = md[1]
    end
  end

  # ---- rendering -----------------------------------------------------------

  # Caller must hold @mutex.
  def emit(text)
    @io.puts(text)
    @io.flush
  end

  # The live block: every running app, with its finished phases and the one
  # in-flight stage counting up. Callers must hold @mutex.
  def render_lines
    lines = []
    @order.each do |name|
      st = @apps[name] or next
      # The app's own elapsed time is on the header rather than only on the
      # running stage: a release script that does not narrate itself through
      # Util.step (the elm / sveltekit / db paths run verbose, not quiet) has no
      # stages to show, and a name sitting there with no clock is exactly the
      # "is this alive?" question the display exists to answer.
      lines << "#{INDENT}#{name}  #{duration(st.elapsed)}"
      st.phases.each { |p| lines << "#{PHASE_INDENT}#{p.label}... #{p.outcome} (#{p.text})" }
      if st.current
        lines << "#{PHASE_INDENT}#{st.current.label}... #{duration(Time.now - st.current.started_at)}"
      end
    end
    lines.map { |l| truncate(l) }
  end

  def redraw
    return unless @tty

    lines = render_lines
    out = +""
    out << "\e[#{@lines_drawn}A" if @lines_drawn > 0
    lines.each { |l| out << "\e[2K" << l << "\n" }
    # The block shrank (an app finished): blank the rows it used to occupy,
    # then step back up so the cursor still sits immediately below the block.
    extra = @lines_drawn - lines.length
    if extra > 0
      extra.times { out << "\e[2K\n" }
      out << "\e[#{extra}A"
    end
    @io.write(out)
    @io.flush
    @lines_drawn = lines.length
  end

  def clear_block
    return unless @tty
    return if @lines_drawn == 0

    out = +"\e[#{@lines_drawn}A"
    @lines_drawn.times { out << "\e[2K\n" }
    out << "\e[#{@lines_drawn}A"
    @io.write(out)
    @io.flush
    @lines_drawn = 0
  end

  def truncate(line)
    max = terminal_width - 1
    return line if line.length <= max

    line[0, [max - 1, 0].max] + "…"
  end

  # A pty that reports no size (`script`, some CI runners, a detached console)
  # answers 0 columns, not nil — and a 0 taken literally truncates every line to
  # a bare ellipsis. Anything implausibly narrow means "unknown", so fall back.
  def terminal_width
    @terminal_width ||= begin
      reported = IO.console&.winsize&.last.to_i
      reported > MIN_PLAUSIBLE_WIDTH ? reported : DEFAULT_WIDTH
    end
  rescue StandardError
    @terminal_width = DEFAULT_WIDTH
  end

  # 45s / 2m31s / 1h04m
  def duration(seconds)
    self.class.duration(seconds)
  end

  def self.duration(seconds)
    s = seconds.round
    return "#{s}s" if s < 60

    m, s = s.divmod(60)
    return format("%dm%02ds", m, s) if m < 60

    h, m = m.divmod(60)
    format("%dh%02dm", h, m)
  end
end

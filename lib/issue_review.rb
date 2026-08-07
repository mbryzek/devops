require 'open3'

# The machinery behind `dev issues review`: the walk through every issue that is
# blocked on a human, with a Claude session summarising each one before it is
# asked about.
#
# WHY A SESSION PER ISSUE AND NOT A RENDER. `dev issues show` already prints the
# body, the timeline and the edges, and that was never enough. The question was
# recorded by a session that had the CODE in context and the person answering
# does not — "can a fix record's baseline version be corrected?" is unanswerable
# from the comment alone and obvious once the two call sites have been read.
# Reading the code is where the value is, so a summary is a session, not a
# formatter.
#
# WHY A WINDOW AND NOT A FAN-OUT. Every summary costs a code-reading session.
# Fanning all N out up front and running them one at a time have the SAME latency
# after the first issue — parallel is parallel — so latency is not what separates
# them. Waste is: a walk abandoned after three answers has paid for N-3 summaries
# nobody read. A window of K bounds that to K, and K is one integer, not a
# first-batch/second-batch staging rule.
#
# WHY THE SUMMARY IS AN ENHANCEMENT AND NEVER A DEPENDENCY. A session can be
# slow, can error, can come back empty. None of those may strand an issue in the
# walk, so every failure falls back to the deterministic render the CLI can
# always produce, and offers a key to run the session again.
module IssueReview
  # K — how many summary sessions are in flight at once. One integer, deliberately:
  # the alternative designs (fan every issue out up front, run them strictly one at
  # a time) are this number at its extremes, so there is nothing here for a
  # first-batch/second-batch special case to be carved out of.
  #
  # Five, because a walk is abandoned in the single digits far more often than it
  # is finished — the number bounds what an abandoned walk wasted, and a queue of
  # 17 does not need 17 sessions to keep one person reading.
  WINDOW = 5

  # How long a summary session gets before the walk stops waiting on it and falls
  # back to the deterministic render. Generous because the session is READING CODE
  # across repos, which is the whole reason it exists; the cost of being too tight
  # is a summary thrown away seconds before it arrived.
  TIMEOUT_SECONDS = 300

  # One issue's summary, however it turned out. `error` is the reason the session
  # produced nothing — the caller renders the deterministic fallback instead and
  # offers a retry — so a Summary is always safe to print.
  Summary = Struct.new(:number, :text, :error) do
    def ok? = error.nil? && !text.to_s.strip.empty?
  end

  # A headless `claude --print` reading ONE issue.
  #
  # READ-ONLY BY CONSTRUCTION, NOT BY INSTRUCTION. It runs unattended with its
  # cwd on a directory holding every checkout on the machine, so "please do not
  # modify anything" in the prompt is the wrong kind of guarantee — it is advice
  # to a model, and the blast radius if it is not followed is somebody's working
  # tree. Edit, Write, NotebookEdit and Bash are denied at the CLI instead, which
  # leaves Read, Grep and Glob: exactly the capability reading code needs, and
  # none of the surface that could change a checkout, push a branch, or write to
  # the tracker. Measured on this fleet — with these denials the session reports
  # both a Bash call and a Write call as "not enabled in this context", and the
  # file it was asked to write does not exist.
  #
  # Its own process GROUP, for the reason the walk's Ctrl-C handling depends on:
  # a group is the thing that can be killed whole, and the terminal signals only
  # its FOREGROUND group — so a Ctrl-C at the prompt does not reach these, and
  # terminating them is the walk's job rather than the shell's.
  class Session
    # Not a list of what to allow: --allowedTools is additive to whatever the
    # machine's settings already permit (measured — Bash ran fine with
    # `--allowedTools "Read Grep Glob"`), so an allowlist here would look like a
    # restriction and be none. Denial is the direction that holds.
    DENIED_TOOLS = "Edit Write NotebookEdit Bash".freeze

    # How long to wait for a TERM before insisting. A model mid-turn does not
    # always stop promptly, and a walk shutting down cannot wait on it.
    TERMINATE_GRACE_SECONDS = 3

    attr_reader :number

    def initialize(number:, prompt:, model:, chdir:, timeout:)
      @number = number
      @prompt = prompt
      @model = model
      @chdir = chdir
      @timeout = timeout
      @state = :new
    end

    def argv
      ["claude", "--print", "--disallowedTools", DENIED_TOOLS, "--model", @model, @prompt]
    end

    # Idempotent, so the window can call it without tracking what it has already
    # started. A spawn failure is recorded as a summary error rather than raised:
    # one machine without `claude` on its PATH must degrade the walk to the
    # deterministic render, not end it.
    def start
      return self unless @state == :new

      @state = :running
      stdin, @out, @wait = Open3.popen2e(*argv, chdir: @chdir, pgroup: true)
      stdin.close
      @deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + @timeout
      # Drain the pipe from the moment it exists. A child that fills the pipe
      # buffer blocks on write, so a summary nobody has reached yet would stall
      # part-written and never finish — this reader thread is what makes
      # "started early" actually mean running.
      @reader = Thread.new { @out.read }
      self
    rescue StandardError => e
      @state = :finished
      @summary = Summary.new(@number, nil, "could not start a summary session: #{e.message}")
      self
    end

    # Whether reading this issue's summary would return immediately. The walk
    # prints "summarizing…" only when it would not.
    def ready?
      return true if @summary
      @state == :running && @reader && !@reader.alive?
    end

    def done? = !@summary.nil? || @state != :running

    # The summary, waiting for the session if it is still running. Computed once
    # and handed back to every later caller: --all reads it in the print pass and
    # the prompt pass reaches the same issue again.
    def summary
      @summary ||= wait_for_summary
    end

    # Kill the whole process group. Called from the walk's `ensure`, so a Ctrl-C,
    # an exception and a normal finish all leave the same thing behind: nothing
    # still running and nothing detached.
    def terminate
      return if @state != :running

      @state = :cancelled
      kill_group("TERM")
      kill_group("KILL") unless @wait.join(TERMINATE_GRACE_SECONDS)
      @reader&.kill
      close_pipe
    end

    private

    def wait_for_summary
      start if @state == :new
      return @summary if @summary
      return Summary.new(@number, nil, "the summary session was cancelled") if @state == :cancelled

      remaining = @deadline - Process.clock_gettime(Process::CLOCK_MONOTONIC)
      if remaining <= 0 || @reader.join(remaining).nil?
        terminate
        return Summary.new(@number, nil, "still running after #{@timeout}s, so it was stopped")
      end

      output = read_output
      status = @wait.value
      close_pipe
      @state = :finished
      return output if output.is_a?(Summary)
      return Summary.new(@number, nil, "the session exited #{status.exitstatus}: #{tail(output)}") unless status.success?

      Summary.new(@number, output.strip, nil)
    end

    # The reader thread re-raises whatever it caught when its value is taken, and
    # a broken pipe there must read as "no summary", not as a crashed walk.
    def read_output
      @reader.value.to_s
    rescue StandardError => e
      Summary.new(@number, nil, "reading the session output failed: #{e.message}")
    end

    def kill_group(signal)
      Process.kill(signal, -@wait.pid)
    rescue Errno::ESRCH, Errno::EPERM, RangeError
      nil
    end

    def close_pipe
      @out.close unless @out.nil? || @out.closed?
    rescue IOError
      nil
    end

    def tail(text, limit = 300)
      s = text.to_s.strip.gsub(/\s+/, " ")
      s.length > limit ? "…#{s[-limit..]}" : s
    end
  end

  # The lookahead window over one walk's issues: `size` UNREAD summary sessions
  # at a time, started in walk order and topped back up as each is consumed.
  #
  # Unread rather than merely running, which is the whole reason the number
  # holds: once the walk has read issue 1's summary, K sessions are running
  # AHEAD of where the walk is, so every issue after the first is a zero-wait.
  # The first issue's session is started before any other because it is first in
  # walk order — there is no special case making that true, which is the point.
  class Window
    attr_reader :size

    def initialize(numbers, size:, &factory)
      @numbers = numbers.dup
      @size = size
      @factory = factory
      @sessions = {}
      @consumed = []
    end

    # This issue's summary, waiting for its session if it is still running. The
    # window is topped up BEFORE the wait as well as after it, so the next K are
    # already in flight while this one is being read rather than starting once it
    # has been answered.
    def take(number)
      fill
      session = @sessions[number] || start(number)
      @consumed << number unless @consumed.include?(number)
      fill
      session.summary
    end

    # Throw a failed or cancelled summary away and run a fresh session for the
    # same issue. Synchronous on purpose: the person is sitting at the prompt
    # waiting for this one, so there is nothing to overlap it with.
    def restart(number)
      @sessions.delete(number)&.terminate
      start(number).summary
    end

    def ready?(number)
      session = @sessions[number]
      !session.nil? && session.ready?
    end

    def in_flight = @sessions.values.reject(&:done?).map(&:number)

    def shutdown = @sessions.each_value(&:terminate)

    private

    def fill
      IssueReview.window_numbers(@numbers, @consumed, @size).each do |number|
        start(number) unless @sessions.key?(number)
      end
    end

    def start(number) = @sessions[number] = @factory.call(number).start
  end

  # Which issues should have a session in flight right now: the next `size` not
  # yet consumed, in walk order. The whole lookahead policy as one pure function,
  # so K stays one integer with nothing else able to disagree with it.
  def self.window_numbers(numbers, consumed, size)
    return [] if size <= 0

    numbers.reject { |n| consumed.include?(n) }.first(size)
  end

  # The per-issue prompt's escape hatches. Single letters, and they match only
  # when they are the WHOLE line: everything else is the answer, which is the
  # common case and must never be swallowed by a command. So "skip the second
  # option" is an answer and "s" is skip. Every argument a command needs — how
  # many days, why dismissed — is asked for afterwards rather than parsed off
  # this line, which is what keeps the rule to one sentence.
  KEYS = {
    "e" => :editor,
    "s" => :skip,
    "z" => :snooze,
    "d" => :dismiss,
    "r" => :retry,
    "q" => :quit,
  }.freeze

  Action = Struct.new(:kind, :text)

  # nil is EOF: stdin closed under the walk and there is nobody left to answer.
  # That is `quit` — every remaining issue stays exactly as it is — and never an
  # empty answer, which would record a blank comment and reopen the issue.
  def self.parse_answer(raw)
    return Action.new(:quit, nil) if raw.nil?

    text = raw.strip
    # An empty line opens $EDITOR, the way `dev issues create` does. The answer
    # that needs more than one line is the one worth not losing to a terminal.
    return Action.new(:editor, nil) if text.empty?

    key = KEYS[text.downcase]
    key ? Action.new(key, nil) : Action.new(:answer, text)
  end
end

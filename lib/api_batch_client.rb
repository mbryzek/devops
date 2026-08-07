require 'set'

class ApiBatchClient

  FIRST_POLL_DELAY = 0.25
  POLL_INTERVAL = 0.35

  # A batch that has not reached a terminal status by here is not "slow", it is
  # a release that is never going to finish on its own. A publish of every
  # bryzek application (22 apps, 64 codegen units) lands in 10-45 seconds, so
  # this is 20x headroom on the slowest normal run — long enough that a real
  # server hiccup still completes, short enough that a wedged batch surfaces
  # while the person who started the deploy is still at the machine.
  DEFAULT_TIMEOUT_SECONDS = 900

  # Raised instead of waiting forever. Carries the batch id, because the recovery
  # is to rerun the publish, and the id is what makes the failed one findable.
  class Timeout < StandardError; end

  # `clock` and `sleeper` exist so the deadline is testable without a test that
  # actually waits 15 minutes.
  def initialize(client,
                 timeout_seconds: DEFAULT_TIMEOUT_SECONDS,
                 clock: -> { Process.clock_gettime(Process::CLOCK_MONOTONIC) },
                 sleeper: ->(seconds) { sleep(seconds) })
    @client = client
    @timeout_seconds = timeout_seconds
    @clock = clock
    @sleeper = sleeper
  end

  # POST /apibuilder/batches
  def create_batch(org, form)
    @client.request(:post, "/apibuilder/batches", form)
  end

  # GET /apibuilder/batches/:id
  def get_batch(org, id)
    @client.request(:get, "/apibuilder/batches/#{id}")
  end

  # Polls until the batch reaches a terminal status (done or error), or until
  # the deadline, whichever comes first. Returns the final batch response.
  #
  # This used to poll for ~30 seconds and then ask "Cancel or keep waiting?" on
  # stdin. Every non-interactive caller — which is every caller that matters, a
  # release runs this from `Util.run` with stdout and stderr redirected to a log
  # file — printed that question somewhere nobody was looking and then blocked on
  # a terminal read that could not be answered. `dev deploy` sat on "Publishing
  # apibuilder specs..." for 23 minutes on 2026-08-07 and only ever ended in a
  # Ctrl-C. A prompt whose output is redirected is not a prompt, it is a hang,
  # so there is no prompt any more: a deadline, and Ctrl-C for the human who is
  # actually watching.
  def poll_until_complete(org, id)
    reported = { done: Set.new, last_completed: {}, last_len: 0 }
    deadline = @clock.call + @timeout_seconds
    last_batch = nil

    @sleeper.call(FIRST_POLL_DELAY)
    loop do
      last_batch = get_batch(org, id)
      report_progress(last_batch, reported)
      if terminal?(last_batch)
        clear_progress_line(reported)
        return last_batch
      end

      if @clock.call >= deadline
        clear_progress_line(reported)
        raise Timeout, timeout_message(id, last_batch)
      end

      @sleeper.call(POLL_INTERVAL)
    end
  end

  # Downloads a zip file from a URL. Returns nil if expired.
  def download_zip(url)
    @client.download(url)
  end

  private

  def terminal?(batch)
    batch["status"] == "done" || batch["status"] == "error"
  end

  # The last progress the server reported is the whole diagnosis: a batch stuck
  # at "codegen 34/64" is a different problem from one that never left 0/64.
  def timeout_message(id, batch)
    progress = (batch&.dig("operations") || []).map do |op_status|
      "#{op_status["operation"]} #{op_status["completed"]}/#{op_status["total"]}"
    end
    [
      "Batch #{id} did not reach a terminal status within #{@timeout_seconds}s (status: #{batch&.fetch("status", nil) || "unknown"}).",
      progress.empty? ? "No progress was reported." : "Last progress: #{progress.join(', ')}.",
      "Nothing was downloaded. Rerun the publish once the batch is healthy.",
    ].join("\n")
  end

  def report_progress(batch, reported)
    operations = batch["operations"] || []
    operations.each do |op_status|
      op = op_status["operation"]
      completed = op_status["completed"]
      total = op_status["total"]

      next if reported[:done].include?(op)

      if completed >= total
        clear_progress_line(reported)
        reported[:done].add(op)
        puts "==> #{op.capitalize} complete"
      elsif completed != reported[:last_completed][op]
        reported[:last_completed][op] = completed
        msg = "==> #{op.capitalize} (#{completed}/#{total})"
        print "\r#{msg}#{' ' * [0, (reported[:last_len] || 0) - msg.length].max}"
        reported[:last_len] = msg.length
        $stdout.flush
      end
    end
  end

  def clear_progress_line(reported)
    if reported[:last_len] && reported[:last_len] > 0
      print "\r#{' ' * reported[:last_len]}\r"
      reported[:last_len] = 0
    end
  end

end

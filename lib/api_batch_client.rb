class ApiBatchClient

  POLL_INTERVALS = [0.25] + [0.35] * 85  # ~30s total before first prompt
  CONTINUE_INTERVAL = 0.35
  CONTINUE_PROMPT_EVERY = 30  # seconds between re-prompts

  def initialize(client)
    @client = client
  end

  # POST /apibuilder/batches
  def create_batch(org, form)
    @client.request(:post, "/apibuilder/batches", form)
  end

  # GET /apibuilder/batches/:id
  def get_batch(org, id)
    @client.request(:get, "/apibuilder/batches/#{id}")
  end

  # Polls until batch reaches a terminal status (done or error).
  # Returns the final batch response.
  def poll_until_complete(org, id)
    reported = { done: Set.new, last_completed: {}, last_len: 0 }

    POLL_INTERVALS.each do |interval|
      sleep(interval)
      batch = get_batch(org, id)
      report_progress(batch, reported)
      return batch if terminal?(batch)
    end

    loop do
      if !prompt_continue
        $stderr.puts "Cancelled."
        exit 1
      end

      elapsed = 0.0
      while elapsed < CONTINUE_PROMPT_EVERY
        sleep(CONTINUE_INTERVAL)
        elapsed += CONTINUE_INTERVAL
        batch = get_batch(org, id)
        report_progress(batch, reported)
        return batch if terminal?(batch)
      end
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

  def prompt_continue
    $stderr.print "Still processing. Cancel or keep waiting? [c/w] "
    $stderr.flush
    answer = $stdin.gets
    return true if answer.nil?
    answer.strip.downcase != "c"
  end

end

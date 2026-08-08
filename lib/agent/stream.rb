require 'json'
require 'time'

# Reading a live session's output (ISS-949).
#
# Sessions are spawned with `--output-format stream-json --verbose`, so the
# session log is JSONL written in real time rather than one blob at exit. That
# is the whole point: `dev agent status` and `dev agent logs` used to show
# `(no output yet)` for the entire life of a HEALTHY multi-hour run, because
# `claude --print` writes nothing until it is done. A wedged session and a
# working one looked identical from outside.
#
# The transform lives HERE, on the read path, and not in the spawn wrapper. It
# is tempting to pipe the session through a formatter and keep the log
# human-readable on disk, and it would be wrong: `Agent::Jobs.spawn_session`
# wraps the command in `sh -c '... ; echo $? > exit_code'`, and that exit code
# is one of the three signals `Agent::Outcome` classifies on. Behind a pipe,
# `$?` is the FORMATTER's status — a session that crashed would file a 0. So the
# redirect stays a plain `>>` of whatever the CLI emits, and nothing between the
# session and the file can lie about how it ended.
#
# Two consequences that shape everything below:
#
#   1. stderr is in the same file (`2>&1`), so not every line is JSON. A CLI
#      that dies prints prose — ISS-783's whole log is the two words
#      "Execution error" — and that prose is the most valuable line in the file.
#      Non-JSON is rendered VERBATIM, never dropped.
#   2. The file is being appended to while it is read, so the last line is
#      routinely a half-written one. A trailing chunk with no newline is
#      incomplete by definition and is skipped rather than parsed.
module Agent
  module Stream
    module_function

    # How much of a tool argument or an error to keep on one line. The status
    # view truncates again at its own width; this only bounds what a single
    # 40KB Write input can do to a log line.
    ARG_LIMIT = 160

    # The input field that says what a tool call is DOING, per tool. Falls back
    # to the first string value, so a tool added after this was written still
    # renders something rather than nothing.
    ARG_KEYS = %w[command file_path pattern path url query prompt description subagent_type].freeze

    # ---- rendering one event ----

    # Zero or more human lines for one parsed event. An array because a `result`
    # is legitimately two things (the final text, then how the run ended), and
    # because an assistant turn is as many lines as its text has.
    #
    # An unrecognised type renders nothing rather than raising. The event
    # vocabulary belongs to the Claude CLI and grows without asking us; a new
    # kind appearing must degrade to silence, not take out `dev agent status`
    # for every issue on the machine.
    def render_event(event, stamp: false)
      lines = case event["type"]
              when "system"    then system_lines(event)
              when "assistant" then block_lines(event)
              when "user"      then tool_result_lines(event)
              when "result"    then result_lines(event)
              else []
              end
      prefix = stamp ? timestamp_prefix(event) : nil
      prefix ? lines.map { |line| "#{prefix}#{line}" } : lines
    end

    # One raw line — JSON or not — as the lines a human should see.
    def render_line(raw, stamp: false)
      text = raw.to_s.strip
      return [] if text.empty?

      begin
        event = JSON.parse(text)
      rescue JSON::ParserError
        # stderr, or a CLI that printed prose on its way out. Verbatim: see the
        # header. This is the line that explains a session nothing else can.
        return [text]
      end
      event.is_a?(Hash) ? render_event(event, stamp: stamp) : [text]
    end

    def system_lines(event)
      case event["subtype"]
      when "init"
        ["session started · model=#{event['model']} · cwd=#{event['cwd']}"]
      when "hook_response"
        # Only a FAILING hook. A hook that fired and passed is noise; one that
        # exited non-zero can be the reason the session did nothing.
        code = event["exit_code"].to_i
        code.zero? ? [] : ["hook #{event['hook_name']} failed (exit #{code})"]
      else
        # `thinking_tokens` and `hook_started` and whatever joins them. These are
        # the BULK of the stream — one turn emits six or more `thinking_tokens` —
        # which is exactly why "tail the last line of the file" is not an
        # implementation of "what is this session doing": that line is almost
        # always one of these.
        []
      end
    end

    def block_lines(event)
      blocks = event.dig("message", "content")
      return [] unless blocks.is_a?(Array)

      blocks.flat_map do |block|
        case block["type"]
        when "text"     then text_lines(block["text"])
        when "tool_use" then ["→ #{block['name']}#{tool_argument(block['input'])}"]
        else []  # thinking, and anything added later: not for this view
        end
      end
    end

    # Tool errors only. A successful tool_result is the session working, which
    # the `→` line above already said, and pasting every result back would make
    # the log longer than the transcript it summarises.
    def tool_result_lines(event)
      blocks = event.dig("message", "content")
      return [] unless blocks.is_a?(Array)

      blocks.select { |block| block["type"] == "tool_result" && block["is_error"] }
            .map { |block| "✗ tool error: #{one_line(result_content(block['content']))}" }
    end

    # How the run ended, and — only when it ended badly — what it said.
    #
    # On success `result` is a VERBATIM repeat of the last assistant text block,
    # which the stream already rendered a moment earlier; printing it again ends
    # every log with the same paragraph twice. On a failure it is the only place
    # the reason appears, so there it is kept.
    #
    # The summary goes LAST either way: it is what `last_line` reports for a
    # finished session, and "how did it end" beats a trailing line of prose.
    def result_lines(event)
      summary = [
        "● #{event['subtype'] || (event['is_error'] ? 'error' : 'done')}",
        duration(event["duration_ms"]),
        turns(event["num_turns"]),
        cost(event["total_cost_usd"]),
      ].compact.join(" · ")
      failed = event["is_error"] || event["subtype"].to_s != "success"
      (failed ? text_lines(event["result"]) : []) + [summary]
    end

    # ---- reading a file ----

    # The last line worth showing, for the one-line status view — or nil when
    # the session has genuinely emitted nothing yet.
    #
    # Read from the END in a bounded window, because this is called once per
    # live claim on every `dev agent status` and a session log runs to megabytes.
    # The window grows only when a window held nothing renderable, which is the
    # thinking_tokens case: a stretch of pure noise longer than 64KB is real.
    def last_line(path, windows: [64 * 1024, 512 * 1024, 4 * 1024 * 1024])
      return nil unless File.file?(path)
      size = File.size(path)
      return nil if size.zero?

      windows.each do |window|
        lines = complete_lines(tail_bytes(path, window, size), cut_at_start: window < size)
        # The LAST rendered line of the last raw line that rendered anything: a
        # `result` event is [final text…, "● success · …"], and the summary is
        # the answer to "how did it end".
        lines.reverse_each do |raw|
          rendered = render_line(raw)
          return rendered.last unless rendered.empty?
        end
        break if window >= size
      end
      nil
    end

    # The log as human lines, newest `limit` of them, oldest first. Bounded read
    # for the same reason `last_line` is bounded — this file grows to megabytes.
    def render_file(path, limit: 200, stamp: true, raw: false, window: 4 * 1024 * 1024)
      return [] unless File.file?(path)
      size = File.size(path)
      lines = complete_lines(tail_bytes(path, window, size), cut_at_start: window < size)
      return lines.last(limit) if raw
      lines.flat_map { |line| render_line(line, stamp: stamp) }.last(limit)
    end

    # `dev agent logs --follow`, after the caller has already printed the
    # history: blocks, rendering each new line as it lands.
    #
    # Starts at EOF by default for exactly that reason — `render_file` just
    # printed everything up to here, and replaying it would double the log.
    #
    # Holds an incomplete trailing line in `pending` rather than rendering it:
    # a partial JSON object is unparseable and would otherwise be echoed as
    # garbage verbatim, one fragment per poll, as the writer finished it.
    def follow(path, out: $stdout, interval: 0.5, stamp: true, raw: false, from_end: true)
      File.open(path, "r") do |file|
        file.seek(0, IO::SEEK_END) if from_end
        pending = +""
        loop do
          chunk = file.read
          if chunk.nil? || chunk.empty?
            sleep interval
            next
          end
          pending << chunk
          complete, pending = split_pending(pending)
          complete.each do |line|
            (raw ? [line] : render_line(line, stamp: stamp)).each { |rendered| out.puts rendered }
          end
          out.flush
        end
      end
    end

    # ---- helpers ----

    # Everything before the final newline, split. A trailing fragment is dropped:
    # the writer is still on it.
    def split_pending(buffer)
      cut = buffer.rindex("\n")
      return [[], buffer] unless cut
      [buffer[0..cut].lines.map(&:chomp), buffer[(cut + 1)..] || +""]
    end

    def tail_bytes(path, window, size)
      File.open(path, "rb") do |file|
        file.seek([size - window, 0].max)
        file.read
      end.to_s.force_encoding(Encoding::UTF_8).scrub
    end

    # Drops the first line when the window cut into the middle of one, and the
    # last when the writer is still on it.
    #
    # `cut_at_start` is passed rather than sniffed. Guessing from the first
    # character would throw away a whole-file read whose first line is stderr
    # prose instead of JSON — which is the ISS-783 log, the one case where the
    # first line is the only line that matters.
    def complete_lines(text, cut_at_start: false)
      lines = text.lines
      lines.shift if cut_at_start
      lines.pop unless text.end_with?("\n")
      lines.map(&:chomp)
    end

    def text_lines(text)
      text.to_s.split("\n").map(&:rstrip).reject(&:empty?)
    end

    def one_line(text)
      truncate(text.to_s.gsub(/\s+/, " ").strip)
    end

    def truncate(text, limit = ARG_LIMIT)
      text.length > limit ? "#{text[0, limit - 1]}…" : text
    end

    # A tool_result's content is a string for most tools and a content-block
    # array for the ones that return images.
    def result_content(content)
      return content.filter_map { |block| block["text"] }.join(" ") if content.is_a?(Array)
      content.to_s
    end

    def tool_argument(input)
      return "" unless input.is_a?(Hash)
      key = ARG_KEYS.find { |candidate| input[candidate].is_a?(String) && !input[candidate].empty? }
      value = key ? input[key] : input.values.find { |v| v.is_a?(String) && !v.empty? }
      value ? " #{one_line(value)}" : ""
    end

    def timestamp_prefix(event)
      raw = event["timestamp"]
      return nil if raw.to_s.empty?
      "[#{Time.parse(raw).localtime.strftime('%H:%M:%S')}] "
    rescue ArgumentError
      nil
    end

    def duration(millis)
      return nil unless millis.is_a?(Numeric)
      seconds = millis / 1000.0
      return "#{seconds.round(1)}s" if seconds < 60
      "#{(seconds / 60).floor}m#{(seconds % 60).round}s"
    end

    def turns(count) = count.is_a?(Numeric) ? "#{count} turns" : nil

    def cost(amount) = amount.is_a?(Numeric) ? format("$%.2f", amount) : nil
  end
end

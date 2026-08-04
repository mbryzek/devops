require 'date'
require 'time'

# Schedule grammar for `devops/agent/producers.yml`, and the due-ness arithmetic
# built on it. Pure functions — no clock of its own, no network — so both are
# directly testable (design §7, Phase 2).
#
# THE SERVER NEVER EVALUATES A SCHEDULE (design §4.2). The registry lives in git
# and only in git; the tick computes "is this due" locally and the platform only
# arbitrates ("did someone already start this run?"). Teaching the platform the
# grammar would mean a second copy of the registry that drifts.
#
# Three spoken forms cover the entire inventory:
#
#   every <n> <unit>              every 1 hour, every 30 minutes
#   daily at <time>               daily at 3:00am
#   weekly on <day> at <time>     weekly on monday at 2:00am
#
# `every` is an elapsed-time rule and needs no timezone. `daily` and `weekly`
# name a wall-clock moment, and are evaluated in the file's one IANA timezone —
# `America/New_York`, not "EDT". An abbreviation names a fixed offset and would
# drift an hour every winter; the IANA zone means 3:00am local year-round across
# both DST transitions.
module Agent
  module Schedule
    class ParseError < StandardError; end

    UNITS = {
      "minute" => 60, "minutes" => 60,
      "hour"   => 3600, "hours" => 3600,
      "day"    => 86_400, "days" => 86_400,
    }.freeze

    DAYS = %w[sunday monday tuesday wednesday thursday friday saturday].freeze

    module_function

    # => { kind: :every,  seconds: Integer }
    #    { kind: :daily,  hour: Integer, minute: Integer }
    #    { kind: :weekly, wday: Integer, hour: Integer, minute: Integer }
    def parse(text)
      s = text.to_s.strip.downcase
      case s
      when /\Aevery\s+(\d+)\s+(\w+)\z/
        n = Regexp.last_match(1).to_i
        unit = Regexp.last_match(2)
        raise ParseError, "unknown interval unit #{unit.inspect} in #{text.inspect} (one of: #{UNITS.keys.uniq.join(', ')})" unless UNITS.key?(unit)
        raise ParseError, "interval must be positive in #{text.inspect}" if n <= 0
        { kind: :every, seconds: n * UNITS.fetch(unit) }
      when /\Adaily\s+at\s+(.+)\z/
        hour, minute = parse_time_of_day(Regexp.last_match(1), text)
        { kind: :daily, hour: hour, minute: minute }
      when /\Aweekly\s+on\s+(\w+)\s+at\s+(.+)\z/
        day = Regexp.last_match(1)
        wday = DAYS.index(day)
        raise ParseError, "unknown day #{day.inspect} in #{text.inspect}" if wday.nil?
        hour, minute = parse_time_of_day(Regexp.last_match(2), text)
        { kind: :weekly, wday: wday, hour: hour, minute: minute }
      else
        raise ParseError,
              "unrecognized schedule #{text.inspect}. Use `every <n> <unit>`, " \
              "`daily at <time>`, or `weekly on <day> at <time>`."
      end
    end

    def parse_time_of_day(text, original)
      m = text.strip.match(/\A(\d{1,2})(?::(\d{2}))?\s*(am|pm)?\z/)
      raise ParseError, "unrecognized time #{text.inspect} in #{original.inspect} (e.g. 3:00am, 14:30)" if m.nil?
      hour = m[1].to_i
      minute = (m[2] || "0").to_i
      meridiem = m[3]
      if meridiem
        raise ParseError, "hour out of range in #{original.inspect}" unless (1..12).cover?(hour)
        hour = 0 if hour == 12
        hour += 12 if meridiem == "pm"
      else
        raise ParseError, "hour out of range in #{original.inspect}" unless (0..23).cover?(hour)
      end
      raise ParseError, "minute out of range in #{original.inspect}" unless (0..59).cover?(minute)
      [hour, minute]
    end

    # Is this schedule due, given when it last ran?
    #
    # `last_run_at` nil means "never ran": always due. For a wall-clock schedule
    # that is deliberate — a producer added to the registry today runs on the
    # next tick rather than waiting until tomorrow's 3am.
    def due?(schedule, last_run_at:, now: Time.now, timezone: nil)
      case schedule.fetch(:kind)
      when :every
        last_run_at.nil? || (now - last_run_at) >= schedule.fetch(:seconds)
      when :daily, :weekly
        occurrence = previous_occurrence(schedule, now: now, timezone: timezone)
        return false if occurrence.nil?
        last_run_at.nil? || last_run_at < occurrence
      else
        raise ParseError, "unknown schedule kind #{schedule[:kind].inspect}"
      end
    end

    # The start of the period this schedule is currently in — the moment it most
    # recently BECAME due. nil when it has never run, the one case with no prior
    # period to sit inside.
    #
    # This is the arbitration guard the tick hands the platform (design §4.2):
    # "has anyone already started a run for the period that is now due?" The
    # server answers it by looking for a run with `started_at >= guard`, which is
    # why the guard must be the START OF THE PERIOD and never the previous run's
    # own `started_at`. A run is always `>=` itself, so passing the latter makes
    # every producer block itself forever after its first successful run — the
    # whole producer subsystem silently becomes one-shot.
    def period_start(schedule, last_run_at:, now: Time.now, timezone: nil)
      case schedule.fetch(:kind)
      when :every
        # No wall-clock boundary exists for an elapsed-time rule, so the period
        # opened exactly one interval after the last run.
        last_run_at.nil? ? nil : last_run_at + schedule.fetch(:seconds)
      when :daily, :weekly
        previous_occurrence(schedule, now: now, timezone: timezone)
      else
        raise ParseError, "unknown schedule kind #{schedule[:kind].inspect}"
      end
    end

    # The most recent wall-clock occurrence of a daily/weekly schedule at or
    # before `now`, in `timezone`. nil for an `every` schedule (it has none).
    #
    # Walks back a CALENDAR DAY at a time rather than subtracting 86_400
    # seconds. That is the whole DST story: across a spring-forward the local
    # 3:00am occurrences are 23 hours apart and across a fall-back 25, so fixed
    # arithmetic would drift the schedule an hour twice a year — exactly what
    # naming the zone was meant to prevent.
    def previous_occurrence(schedule, now: Time.now, timezone: nil)
      return nil unless %i[daily weekly].include?(schedule[:kind])
      wday = schedule[:kind] == :weekly ? schedule.fetch(:wday) : nil
      in_zone(timezone) do
        local = now.getlocal
        date = Date.new(local.year, local.month, local.day)
        # 8 days covers a weekly schedule whose day is "yesterday last week".
        9.times do
          if wday.nil? || date.wday == wday
            candidate = Time.local(date.year, date.month, date.day, schedule.fetch(:hour), schedule.fetch(:minute), 0)
            return candidate if candidate <= now
          end
          date -= 1
        end
        nil
      end
    end

    # Run a block with the process timezone set to an IANA zone, restoring it
    # after. Ruby's stdlib Time has no per-object IANA zone support, but it
    # honours TZ against the OS zoneinfo database, which is the same data
    # ActiveSupport's tzinfo would read. `dev agent tick` is a one-shot,
    # single-threaded CLI, so a scoped ENV mutation is safe here in a way it
    # would not be inside a server.
    def in_zone(timezone)
      return yield if timezone.nil? || timezone.to_s.empty?
      previous = ENV["TZ"]
      ENV["TZ"] = timezone.to_s
      yield
    ensure
      ENV["TZ"] = previous unless timezone.nil? || timezone.to_s.empty?
    end

    # When this schedule next fires, for `dev agent producers` to display.
    def next_due(schedule, last_run_at:, now: Time.now, timezone: nil)
      case schedule.fetch(:kind)
      when :every
        return now if last_run_at.nil?
        last_run_at + schedule.fetch(:seconds)
      when :daily, :weekly
        occurrence = previous_occurrence(schedule, now: now, timezone: timezone)
        return now if occurrence.nil? || last_run_at.nil? || last_run_at < occurrence
        in_zone(timezone) do
          date = Date.new(occurrence.getlocal.year, occurrence.getlocal.month, occurrence.getlocal.day) + 1
          9.times do
            if schedule[:kind] == :daily || date.wday == schedule.fetch(:wday)
              return Time.local(date.year, date.month, date.day, schedule.fetch(:hour), schedule.fetch(:minute), 0)
            end
            date += 1
          end
          nil
        end
      end
    end

    def describe(schedule)
      case schedule.fetch(:kind)
      when :every
        seconds = schedule.fetch(:seconds)
        unit, div = seconds % 86_400 == 0 ? ["day", 86_400] : (seconds % 3600 == 0 ? ["hour", 3600] : ["minute", 60])
        n = seconds / div
        "every #{n} #{unit}#{n == 1 ? '' : 's'}"
      when :daily
        "daily at #{format('%02d:%02d', schedule[:hour], schedule[:minute])}"
      when :weekly
        "weekly on #{DAYS[schedule.fetch(:wday)]} at #{format('%02d:%02d', schedule[:hour], schedule[:minute])}"
      end
    end
  end
end

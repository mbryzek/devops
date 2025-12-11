require 'json'

class Healthcheck
  attr_reader :status, :error_message

  def initialize(data, error_message: nil)
    @status = data['status'].to_s
    if @status.empty?
        raise ArgumentError, "status is required: #{data.inspect}"
    end
    @job_server = data['job_server'].to_s == "true"
    @error_message = error_message
  end

  def healthy?
    @status == "healthy"
  end

  def job_server?
    @job_server
  end

  # Fatal errors won't recover - no point waiting
  def fatal?
    @status == "fatal"
  end

  def Healthcheck.from_json(json)
    if json.nil? || json.empty?
        DOWN
    else
        begin
            parsed = JSON.parse(json)
            # Handle both array and object responses
            data = parsed.is_a?(Array) ? parsed.first : parsed
            if data.is_a?(Hash)
                # Check if this is an error response (has discriminator but no status)
                if data['status']
                    Healthcheck.new(data)
                elsif data['discriminator'] == 'validation'
                    # Validation errors are fatal - won't recover
                    FATAL.tap { |h| h.instance_variable_set(:@error_message, data['message']) }
                else
                    DOWN
                end
            else
              DOWN
            end
        rescue JSON::ParserError => e
            DOWN
        end
    end
  end

  DOWN = Healthcheck.new({ "status" => "down"})
  FATAL = Healthcheck.new({ "status" => "fatal"})
  UNKNOWN = Healthcheck.new({ "status" => "unknown"})
end

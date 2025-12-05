require 'json'

class Healthcheck
  attr_reader :status

  def initialize(data)
    @status = data['status'].to_s
    if @status.empty?
        raise ArgumentError, "status is required: #{data.inspect}"
    end
    @job_server = data['job_server'].to_s == "true"
  end

  def healthy?
    @status == "healthy"
  end

  def job_server?
    @job_server
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
                Healthcheck.new(data)
            else
                DOWN
            end
        rescue JSON::ParserError => e
            puts "WARNING: Failed to parse healthcheck response: #{json.inspect}"
            DOWN
        end
    end
  end

  DOWN = Healthcheck.new({ "status" => "down"})
  UNKNOWN = Healthcheck.new({ "status" => "unknown"})
end

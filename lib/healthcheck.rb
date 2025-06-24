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
    if json.empty?
        DOWN
    else
        begin
            Healthcheck.new(JSON.parse(json))
        rescue JSON::ParserError
            DOWN
        end
    end
  end

  DOWN = Healthcheck.new({ "status" => "down"})
  UNKNOWN = Healthcheck.new({ "status" => "unknown"})
end

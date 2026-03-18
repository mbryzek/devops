class ApiBatchClient

  POLL_INTERVALS = [0.25, 0.5] + [1.0] * 28  # ~30s total before first prompt
  CONTINUE_INTERVAL = 1.0
  CONTINUE_PROMPT_EVERY = 30  # seconds between re-prompts

  def initialize(client)
    @client = client
  end

  # POST /apibuilder/:org/batches
  def create_batch(org, form)
    path = "/apibuilder/#{org}/batches"
    response = request(:post, path, form)
    handle_response(response, "Create batch for #{org}")
  end

  # GET /apibuilder/:org/batches/:id
  def get_batch(org, id)
    path = "/apibuilder/#{org}/batches/#{id}"
    response = request(:get, path)
    handle_response(response, "Get batch #{id} for #{org}")
  end

  # Polls until batch reaches a terminal status (done or error).
  # Returns the final batch response.
  def poll_until_complete(org, id)
    POLL_INTERVALS.each do |interval|
      sleep(interval)
      batch = get_batch(org, id)
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
        return batch if terminal?(batch)
      end
    end
  end

  # Downloads a file from a URL and returns the raw body
  def download_zip(url)
    uri = URI.parse(url)
    http = Net::HTTP.new(uri.host, uri.port)
    http.use_ssl = uri.scheme == "https"
    http.open_timeout = 30
    http.read_timeout = 300

    response = http.request(Net::HTTP::Get.new(uri.request_uri))
    code = response.code.to_i
    if code == 200
      response.body
    elsif code == 404 || code == 410
      nil
    else
      Util.exit_with_error("Failed to download zip: HTTP #{code}")
    end
  end

  private

  def terminal?(batch)
    batch["status"] == "done" || batch["status"] == "error"
  end

  def prompt_continue
    $stderr.print "Still processing. Cancel or keep waiting? [c/w] "
    $stderr.flush
    answer = $stdin.gets
    return true if answer.nil?
    answer.strip.downcase != "c"
  end

  def request(method, path, body = nil)
    uri = URI.parse("#{@client.base_uri}#{path}")
    http = Net::HTTP.new(uri.host, uri.port)
    http.use_ssl = uri.scheme == "https"
    http.open_timeout = 30
    http.read_timeout = 300

    req = case method
          when :get then Net::HTTP::Get.new(uri.request_uri)
          when :post then Net::HTTP::Post.new(uri.request_uri)
          end

    req["Content-Type"] = "application/json"
    if @client.token
      req["Authorization"] = "Basic " + Base64.strict_encode64("#{@client.token}:")
    end
    req.body = JSON.generate(body) if body

    http.request(req)
  rescue Errno::ECONNREFUSED
    Util.exit_with_error("Cannot connect to #{@client.base_uri}. Is the server running?")
  rescue SocketError => e
    Util.exit_with_error("Cannot connect to #{@client.base_uri}: #{e.message}")
  end

  def handle_response(response, context)
    code = response.code.to_i
    case code
    when 200, 201
      JSON.parse(response.body)
    when 404
      raise ApibuilderClient::Error, "#{context}: Not found (404)"
    when 401
      raise ApibuilderClient::Error, "#{context}: Unauthorized. Check your API token in ~/.apibuilder/config"
    when 422
      errors = JSON.parse(response.body)
      messages = errors.map { |e| e["message"] || e.to_s }.join("\n  ")
      raise ApibuilderClient::Error, "#{context}: Validation errors:\n  #{messages}"
    else
      message = begin
                  parsed = JSON.parse(response.body)
                  parsed["message"] || response.body
                rescue JSON::ParserError
                  response.body
                end
      raise ApibuilderClient::Error, "#{context}: HTTP #{code}\n#{message}"
    end
  end

end

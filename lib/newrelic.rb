require 'json'
require 'net/http'
require 'openssl'
require 'timeout'
require 'uri'

# The NerdGraph seam: one place that turns an NRQL string into rows.
#
# WHY THIS IS A FILE AND NOT THREE LINES OF `curl` IN A PLAYBOOK. Every NewRelic
# read this fleet does today is a session hand-rolling a POST from an example in
# a prompt, and that shape has already produced one silent wrong answer worth an
# issue: ISS-635, where the key the playbooks named was revoked and every query
# came back `{"results": []}`. An empty result set from NerdGraph is not an
# error — 200, well-formed body, no `errors` key on some paths — and an empty
# graph is exactly what a healthy quiet system looks like. So the failure mode of
# "unauthenticated" is "reports that nothing is wrong".
#
# Everything below exists to make that impossible:
#
#   - no key            => raises before any request is made
#   - HTTP != 200       => raises with the status
#   - GraphQL `errors`  => raises with the first message, even on a 200
#   - `nrql` absent     => raises, rather than returning [] for a malformed body
#
# `[]` therefore means one thing only: the query ran, authenticated, and matched
# no rows. A caller may treat that as data. Nothing else here can produce it.
#
# NEVER LOG, PRINT, OR INTERPOLATE THE KEY. It arrives as an argument, goes into
# one header, and is not stored on any object this returns. `Agent::Redact`
# scrubs `NRAK-...` from session transcripts as a backstop, but a backstop is not
# a licence — this runner is shared and a command line is public (ISS-961).
module Newrelic
  # The one account this fleet has. Hardcoded for the same reason
  # `ApiProducers::REPOS` is: there is exactly one, and a discovery mechanism
  # would be more machinery than the fact it discovers. It is not a secret — it
  # appears in every NewRelic URL Mike opens — so unlike the key it is safe here.
  ACCOUNT_ID = 7724695

  ENDPOINT = "https://api.newrelic.com/graphql".freeze

  # Generous, because NRQL over a 150-day window with a FACET is genuinely slow,
  # and the caller with the tightest deadline (the tick) runs this once a day.
  TIMEOUT_SECONDS = 30

  # The variable name is the one `Agent::Credentials` hands to a session, so a
  # human who read their assignment block can run the same command this does.
  KEY_ENV = "NEWRELIC_USER_KEY".freeze

  Error = Class.new(StandardError)

  module_function

  # Rows for one NRQL query, as an Array<Hash> with NewRelic's own key names
  # (`facet`, `sum.GigabytesIngested`, ...). Raises Newrelic::Error for every
  # way this can fail to be a real answer — see the header.
  def nrql(query, key:, account_id: ACCOUNT_ID, http: nil)
    raise Error, missing_key_message if key.to_s.empty?

    body = post(graphql_body(query, account_id), key: key, http: http)
    errors = body["errors"]
    raise Error, "NerdGraph: #{errors.map { |e| e["message"] }.compact.join('; ')}" if errors.is_a?(Array) && !errors.empty?

    results = body.dig("data", "actor", "account", "nrql", "results")
    # NOT `|| []`. A body without this path is a shape we do not understand, and
    # answering "no rows" for it is the ISS-635 failure with a different cause.
    raise Error, "NerdGraph returned no nrql results for: #{query}" if results.nil?

    results
  end

  # Several queries in one round of threads. NerdGraph bills nothing per request
  # and the measurement below needs several independent windows; serially that is
  # that many round trips of up to TIMEOUT_SECONDS each on the tick's path.
  #
  # Returns {name => rows}. An exception in ANY thread propagates out of `value`,
  # so a partial answer can never be mistaken for a complete one — a measurement
  # missing one of its queries would render an issue body with a hole in it.
  #
  # `report_on_exception = false` because the caller HANDLES the exception, at
  # `value`. Left on, Ruby also dumps a backtrace per failed thread to stderr the
  # moment it raises — so one NewRelic outage writes several backtraces into
  # launchd's log for a condition the tick deliberately treats as unremarkable,
  # which is how a log stops being read.
  def nrql_all(queries, key:, account_id: ACCOUNT_ID, http: nil)
    queries.map { |name, query|
      thread = Thread.new { nrql(query, key: key, account_id: account_id, http: http) }
      thread.report_on_exception = false
      [name, thread]
    }.to_h.transform_values(&:value)
  end

  def graphql_body(query, account_id)
    JSON.generate(
      query: "{ actor { account(id: #{Integer(account_id)}) { nrql(query: #{query.to_json}) { results } } } }",
    )
  end

  # `http` is the test seam and the only one: everything above it is pure string
  # handling, so a test can assert the failure taxonomy without a network.
  def post(json, key:, http: nil)
    return http.call(json, key) if http

    uri = URI(ENDPOINT)
    request = Net::HTTP::Post.new(uri)
    request["Content-Type"] = "application/json"
    request["API-Key"] = key
    request.body = json

    response = Net::HTTP.start(uri.hostname, uri.port, use_ssl: true,
                                                       open_timeout: TIMEOUT_SECONDS,
                                                       read_timeout: TIMEOUT_SECONDS) do |conn|
      conn.request(request)
    end
    # 401/403 come back with a JSON body that has no `errors` key, so the status
    # check has to be its own arm rather than folded into the parse below.
    raise Error, "NerdGraph HTTP #{response.code}" unless response.code == "200"

    JSON.parse(response.body)
  rescue JSON::ParserError => e
    raise Error, "NerdGraph returned a body that is not JSON (#{e.message})"
  # EVERY transport failure becomes a Newrelic::Error, so that this client has
  # exactly ONE error type and a caller can contain it with one rescue.
  #
  # This is not tidiness. `Net::HTTP` raises SocketError on a DNS failure,
  # Net::OpenTimeout on an unreachable host and Errno::ECONNRESET on a dropped
  # connection, and none of them is a Newrelic::Error — so the tick's
  # `rescue Newrelic::Error` would not have caught them. They would have reached
  # phase_b's StandardError backstop as a WORK PHASE CRASH, on every runner
  # simultaneously, blaming each machine for a third party being unreachable and
  # skipping that tick's reap and claim to do it.
  rescue SocketError, SystemCallError, IOError, Timeout::Error, OpenSSL::SSL::SSLError => e
    raise Error, "NerdGraph unreachable (#{e.class}: #{e.message})"
  end

  def missing_key_message
    "#{KEY_ENV} is not set. Put a live NewRelic USER key (NRAK-...) in the env repo at " \
      "api_keys/newrelic, or export #{KEY_ENV}. `dev agent doctor` reports whether this machine " \
      "resolves it. Refusing to query unauthenticated: NerdGraph answers an unauthenticated read " \
      "with an empty result set, which reads exactly like a healthy account (ISS-635)."
  end
end

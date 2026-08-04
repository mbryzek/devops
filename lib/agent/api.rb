require 'time'
require 'uri'
require 'agent/paths'

# Every platform call the dispatcher makes, in one place.
#
# Two reasons this is a module and not inline in the tick:
#
#  1. `lib/api_client.rb` is the ONE network seam, so `with_stubbed_api` in the
#     test helper can fake the whole platform. Routing every agent call through
#     here keeps that true and puts the paths under test.
#  2. Auth differs by scope and getting it wrong is a silent 401 loop. Fleet
#     endpoints (`/agent/...`) and the issue-lease endpoints are runner-scoped
#     and present the runner token; registration has no runner token yet and
#     presents the Otto AI token the machine already holds (design §4.5).
module Agent
  module Api
    # Issue-scoped resources live under the playbook tenant, exactly like
    # `dev issues` — /playbook/issue/leases, not /issue/leases.
    TENANT = "playbook".freeze

    module_function

    def endpoint(use_localhost:)
      ApiClient.tenant_endpoint(TENANT, use_localhost: use_localhost)
    end

    def ai_token(use_localhost:)
      ApiClient.ai_token(use_localhost: use_localhost) or
        raise ApiError, "No AI API token stored. Run `dev auth ai provision#{use_localhost ? ' --localhost' : ''}` on this machine."
    end

    def request(method, path, token:, use_localhost:, body: nil)
      ApiClient.request(endpoint(use_localhost: use_localhost), method, path, body: body, as_token: token)
    end

    # ---- fleet (`agent_fleet` auth, non-tenant paths) ----
    #
    # NOT platform-admin, though it was declared that way until ISS-341. Both
    # tokens below belong to the Otto AI user, which is a `playbook` admin with
    # no email -- neither the platform-tenant check nor the verified-email
    # bridge admits it, so every one of these endpoints 401'd in production.
    # The `agent_fleet` scheme admits the AI actor by id.

    # Upsert on hardware_uuid. Returns { "runner" => {...}, "token" => "..." }.
    # The hardware UUID is the authority and this file is only a cache, so a
    # machine that loses ~/.platform/agent.identity gets its existing row back
    # rather than becoming a ghost.
    def register_runner(payload, use_localhost:)
      request(:post, "/agent/runners", token: ai_token(use_localhost: use_localhost),
                                       use_localhost: use_localhost, body: payload)
    end

    def runners(token:, use_localhost:)
      request(:get, "/agent/runners", token: token, use_localhost: use_localhost) || []
    end

    def runner_heartbeat(runner_id, token:, use_localhost:)
      request(:post, "/agent/runners/#{runner_id}/heartbeat", token: token, use_localhost: use_localhost)
    end

    def update_runner(runner_id, form, token:, use_localhost:)
      request(:put, "/agent/runners/#{runner_id}", token: token, use_localhost: use_localhost, body: form)
    end

    # ---- producers ----

    def producer_runs(token:, use_localhost:, producer_key: nil, limit: 100, offset: 0)
      params = { "limit" => limit, "offset" => offset }
      params["producer_key"] = producer_key if producer_key
      request(:get, "/agent/producers/runs?#{URI.encode_www_form(params)}",
              token: token, use_localhost: use_localhost) || []
    end

    # Compare-and-set, not a scheduler: the server creates the run atomically
    # unless one is in flight for this key or one started after
    # `if_no_run_since`.
    #
    # The "nothing happened" answer is a 200 carrying `agent_producer_run_start`
    # with `run` ABSENT — not a 204. API Builder refuses to let one resource vary
    # its type across 2xx codes (`cannot have varying response types for 2xx`),
    # so the emptiness moved from the status line into the body. Unwrapped here
    # so every caller still just sees "a run, or nil".
    def start_producer_run(key, runner_id:, if_no_run_since:, token:, use_localhost:)
      body = { runner_id: runner_id }
      body[:if_no_run_since] = if_no_run_since.utc.iso8601 if if_no_run_since
      res = request(:post, "/agent/producers/#{URI.encode_www_form_component(key)}/runs",
                    token: token, use_localhost: use_localhost, body: body)
      res && res["run"]
    end

    def finish_producer_run(run_id, result:, issue_number: nil, token:, use_localhost:)
      body = { result: result }
      body[:issue_number] = issue_number if issue_number
      request(:put, "/agent/producers/runs/#{run_id}", token: token, use_localhost: use_localhost, body: body)
    end

    # ---- issue leases ----

    # `is_active` is REQUIRED on the server with a default of true (API Builder
    # rejects a defaulted optional parameter), so it is always sent explicitly
    # rather than left to omission — a filter you cannot see in the URL is a
    # filter you forget is there.
    def leases(token:, use_localhost:, is_active: true, runner_id: nil, issue_number: nil, limit: 100, offset: 0)
      params = { "is_active" => is_active }
      params["runner_id"] = runner_id if runner_id
      params["issue_number"] = issue_number if issue_number
      params.merge!("limit" => limit, "offset" => offset)
      request(:get, "/#{TENANT}/issue/leases?#{URI.encode_www_form(params)}",
              token: token, use_localhost: use_localhost) || []
    end

    # Every lease an issue has ever had, oldest first. The lease table IS the
    # attempt history (one row per attempt), so this is what "which attempt is
    # this" and `dev agent runs --issue N` both read.
    #
    # Two calls because `is_active` is a required boolean: there is no "either"
    # value to ask for. Only the reap path and an explicit history query pay it.
    def issue_lease_history(issue_number, token:, use_localhost:)
      [true, false].flat_map do |active|
        leases(token: token, use_localhost: use_localhost, issue_number: issue_number, is_active: active)
      end.sort_by { |lease| lease["created"].to_s }
    end

    # The lease, or nil when nothing is claimable.
    #
    # "Nothing claimable" is a 200 carrying `issue_lease_claim` with `lease`
    # ABSENT, not a 204: API Builder refuses to let a resource vary its type
    # across 2xx codes. 422 (an unknown runner_id, i.e. a client bug) is NOT
    # emptiness and must not be swallowed here.
    def claim(runner_id:, token:, use_localhost:)
      res = request(:post, "/#{TENANT}/issue/leases", token: token, use_localhost: use_localhost,
                                                      body: { runner_id: runner_id })
      res && res["lease"]
    end

    # 409 => the lease expired or was reassigned. The job must die.
    def heartbeat_lease(lease_id, token:, use_localhost:)
      request(:post, "/#{TENANT}/issue/leases/#{lease_id}/heartbeat", token: token, use_localhost: use_localhost)
    end

    # Releasing reverts the issue to `open` only if it is still exactly
    # `claimed`, so a force-release cannot clobber forward progress a session
    # already made. That is why `dev agent release` needs no status check of its
    # own.
    def release_lease(lease_id, token:, use_localhost:)
      request(:delete, "/#{TENANT}/issue/leases/#{lease_id}", token: token, use_localhost: use_localhost)
    end

    # ---- issues (the tracker itself, AI-token scoped like `dev issues`) ----

    def issue(number, use_localhost:)
      request(:get, "/#{TENANT}/issues/#{number}", token: ai_token(use_localhost: use_localhost),
                                                   use_localhost: use_localhost)
    end

    def issue_comments(number, use_localhost:)
      request(:get, "/#{TENANT}/issues/#{number}/comments?limit=101&offset=0",
              token: ai_token(use_localhost: use_localhost), use_localhost: use_localhost) || []
    end

    # Always internal. Everything an automated actor writes is a note to the
    # team; the club that filed an issue is replied to by a person, from
    # playbook-admin. Enforced server-side too (IssuesService rejects a `shared`
    # comment from the AI user) — sent explicitly so it stays true here as well.
    def comment(number, text, use_localhost:)
      request(:post, "/#{TENANT}/issues/#{number}/comments",
              token: ai_token(use_localhost: use_localhost), use_localhost: use_localhost,
              body: { body: text, visibility: "internal" })
    end

    def set_status(number, status, comment: nil, url: nil, use_localhost:)
      body = { status: status }
      if comment && !comment.empty?
        body[:comment] = comment
        body[:visibility] = "internal"
      end
      body[:url] = url if url && !url.empty?
      request(:put, "/#{TENANT}/issues/#{number}/status",
              token: ai_token(use_localhost: use_localhost), use_localhost: use_localhost, body: body)
    end

    def create_issue(form, use_localhost:)
      request(:post, "/#{TENANT}/issues", token: ai_token(use_localhost: use_localhost),
                                          use_localhost: use_localhost, body: form)
    end

    def issues(statuses:, use_localhost:, limit: 200)
      params = { "statuses" => Array(statuses), "limit" => limit, "offset" => 0 }
      request(:get, "/#{TENANT}/issues?#{URI.encode_www_form(params)}",
              token: ai_token(use_localhost: use_localhost), use_localhost: use_localhost) || []
    end
  end
end

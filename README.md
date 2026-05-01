# devops

We are using [Apple's Pkl](https://github.com/apple/pkl) to manage our configuration files.

## Deploying Scala applications to Kubernetes

```
# Build Docker image and push to registry
./bin/k8s-build --app platform --tag 0.1.4

# Deploy to Kubernetes
./bin/k8s-deploy --app platform --tag 0.1.4
```

## Measure uptime

```
uptime-checker.sc https://idempotent.io/_internal_/healthcheck
```

## Generate JSON configuration

```
./generate-json.rb
```

## Using pkl

```
brew install pkl
pkl eval platform/config.pkl --format json
```

## Platform metrics CLI

```
bin/platform-metrics.sc <subcommand> [options]
```

### Subcommands

#### record-point

Record a single data point for a metric. Idempotent — re-posting the same `(metric, date)` updates the value. Auto-creates the metric row if it does not exist yet.

```
bin/platform-metrics.sc record-point \
  --tenant hemlockpoint \
  --series-key water \
  --metric-key well_pump_total_gpd \
  --date 2026-04-27 \
  --value 1187
```

Output: `OK metric_point=mp_abc123`

#### record-points (bulk)

Record many data points in **one** request. Body is a JSON array of `{series_key, metric_key, date, value}` objects, read from a file (use `-` for stdin). All-or-nothing: if any entry is invalid, no writes occur and 422 is returned with all errors. Idempotent like single-point — safe to retry the whole payload.

```
bin/platform-metrics.sc record-points --tenant hemlockpoint --file /tmp/points.json
echo '[...]' | bin/platform-metrics.sc record-points --tenant hemlockpoint --file -
```

Output: `OK n_points=35`

#### set-metric

Upsert a metric by `(series_key, metric_key)`. Auto-creates the metric if it does not exist; otherwise updates only the metadata fields you pass (absent fields are preserved). Idempotent.

Implementation: a single `POST /:tenant_id/metrics/metrics` to the server-side upsert endpoint — no client-side GET-lookup-then-PUT.

```
bin/platform-metrics.sc set-metric \
  --tenant hemlockpoint \
  --series-key water \
  --metric-key well_pump_total_gpd \
  --name "Well Pump Total GPD" \
  --unit gpd \
  --aggregation avg
```

Output: `OK metric=m_abc123`

### Config file

`~/.platform/config` — HOCON format, profile-keyed:

```hocon
default {
  api_url = "https://api.platform.com"
  token = "tok_xxxxxxxxxxxx"
}
```

Lookup precedence (highest wins):

1. `--token` / `--api-url` CLI flags
2. `PLATFORM_TOKEN` / `PLATFORM_API_URL` environment variables
3. `~/.platform/config` profile (default `default`, override with `--profile <name>`)

If no token is found, the script exits non-zero with a message pointing to the config file.

### Global flags

| Flag | Description |
|------|-------------|
| `--token <tok>` | Platform API token |
| `--api-url <url>` | API base URL |
| `--profile <name>` | Config profile (default: `default`) |
| `--verbose` | Print request URL, headers (token redacted), body, and response |
| `--dry-run` | Print the requests that would be sent, then exit 0 without sending |

### Exit codes

| Code | Meaning |
|------|---------|
| 0 | Success |
| 1 | Validation error (4xx from server, or invalid CLI args) |
| 2 | Server error (5xx) |
| 3 | Network/connection error |
| 4 | Missing token or API URL config |

### Tests

```
scala-cli run test/PlatformMetricsSpec.sc --
```

Run from the `devops/` directory.

## Kubernetes scripts

- `k8s-build` - Build Docker image and push to registry
- `k8s-deploy` - Deploy application to Kubernetes
- `k8s-lb-create` - Create DigitalOcean load balancer
- `k8s-lb-configure` - Configure HTTPS on load balancer
- `k8s-secrets` - Sync environment secrets to Kubernetes

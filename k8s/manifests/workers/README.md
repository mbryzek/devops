# workers k8s manifests

Hand-written manifests (not generated via `generate-k8s.rb`) because this is the
only non-Scala app in the cluster — templating one app isn't a win.

Renamed from `court-reserve-workers` (the repo + image are now `workers`). The
old `../court-reserve-workers/` manifests are kept until the cutover below
completes, then deleted.

## Cutover (zero-downtime) — run once

The platform reaches the worker by k8s Service DNS, so the new Service must be
up and the platform pointed at it BEFORE the old one is retired:

```bash
# 1. Build + push the new image (from the workers repo): registry.digitalocean.com/bryzek/workers
#    (workers/bin/build-and-push.sh)

# 2. Create the new cluster Secret + ConfigMap (copy values from the old ones):
kubectl get secret    court-reserve-workers-secrets -n bryzek-production -o yaml | \
  sed 's/court-reserve-workers-secrets/workers-secrets/' | kubectl apply -f -
kubectl get configmap court-reserve-workers-config  -n bryzek-production -o yaml | \
  sed 's/court-reserve-workers-config/workers-config/'   | kubectl apply -f - 2>/dev/null || true

# 3. Apply the new manifests (PVC + StatefulSet + Service):
#    NOTE: a fresh StatefulSet gets a fresh browser-profile PVC, so the warm
#    Cloudflare-evasion profile is LOST — expect a few more CF challenges until
#    it re-warms. Acceptable; it self-heals.
kubectl apply -f k8s/manifests/workers/

# 4. Flip the platform's WORKERS_URL / CONF_WORKER_BASE_URL to the new Service:
#    http://workers.bryzek-production.svc.cluster.local:8787
#    (cluster Secret/ConfigMap for the platform — set it where CONF_WORKER_BASE_URL lives)
#    then redeploy the platform and verify a real court-reserve batch + clubaid login succeed.

# 5. Once verified, retire the old StatefulSet/Service/PVC/secret/configmap:
kubectl delete -f k8s/manifests/court-reserve-workers/
kubectl delete secret court-reserve-workers-secrets configmap court-reserve-workers-config -n bryzek-production
```

Also update the app-registration config (the `env/apps/.../config.pkl` that drives
`bin/release` — `name`, `build_script`, `manifests_dir = k8s/manifests/workers`,
`rollout_target = statefulset/workers`) so future `release --app workers` targets
the new objects. That config lives outside this repo.

## Internal DNS

Platform calls this service at:

```
http://workers.bryzek-production.svc.cluster.local:8787
```

No public Ingress — internal only.

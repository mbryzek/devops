# court-reserve-workers k8s manifests

Hand-written manifests (not generated via `generate-k8s.rb`) because this is the
only non-Scala app in the cluster — templating one app isn't a win.

## Deploy

```bash
# Standard release: tag, build+push image, apply manifests, wait for rollout.
devops/bin/release --app court-reserve-workers

# If env vars changed in env/apps/court-reserve-workers/, also sync them.
# (release does NOT touch ConfigMap/Secret — same convention as the other apps.)
devops/bin/k8s-secrets --app court-reserve-workers
```

The release script reads `app.docker_k8s` in `env/apps/court-reserve-workers/config.pkl`
to find the build script, manifests dir, and rollout target. It applies every
`*.yaml` in this directory with `__IMAGE_TAG__` substituted.

## Internal DNS

Platform calls this service at:

```
http://court-reserve-workers.bryzek-production.svc.cluster.local:8787
```

No public Ingress — internal only.

# workers k8s manifests

Hand-written manifests (not generated via `generate-k8s.rb`) because this is the
only non-Scala app in the cluster — templating one app isn't a win.

## Deploy

```bash
# Standard release: tag, build+push image, sync Secret/ConfigMap from the
# env repo, apply manifests, wait for rollout.
devops/bin/release --app workers

# To push env-var changes WITHOUT a release (running pods only pick them up
# on their next restart/rollout):
devops/bin/k8s-secrets --app workers
```

Applies every `*.yaml` here with `__IMAGE_TAG__` substituted. The container reads
`workers-secrets` (Secret) + `workers-config` (ConfigMap, optional) and mounts the
`workers-browser-profile` PVC.

## Internal DNS

Platform calls this service at:

```
http://workers.bryzek-production.svc.cluster.local:8787
```

No public Ingress — internal only.

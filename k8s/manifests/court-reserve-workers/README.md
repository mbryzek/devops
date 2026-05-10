# court-reserve-workers k8s manifests

Hand-written manifests (not generated via `generate-k8s.rb`) because this is the
only non-Scala app in the cluster — templating one app isn't a win.

## Deploy

```bash
# 1) Push image (from court-reserve-workers repo)
./bin/build-and-push.sh                     # tag = `sem-info tag latest`

# 2) Sync env vars to k8s (Secret + ConfigMap)
devops/bin/k8s-secrets --app court-reserve-workers

# 3) Apply manifests
TAG=$(git -C ~/code/court-reserve-workers tag | sort -V | tail -1)
sed "s/__IMAGE_TAG__/${TAG}/g" devops/k8s/manifests/court-reserve-workers/statefulset.yaml \
  | kubectl apply -f -
kubectl apply -f devops/k8s/manifests/court-reserve-workers/service.yaml
kubectl apply -f devops/k8s/manifests/court-reserve-workers/pvc.yaml

# 4) Verify
kubectl rollout status statefulset/court-reserve-workers -n bryzek-production
kubectl get pvc -n bryzek-production crw-browser-profile
```

## Internal DNS

Platform calls this service at:

```
http://court-reserve-workers.bryzek-production.svc.cluster.local:8787
```

No public Ingress — internal only.

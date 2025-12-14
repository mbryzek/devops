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

## Kubernetes scripts

- `k8s-build` - Build Docker image and push to registry
- `k8s-deploy` - Deploy application to Kubernetes
- `k8s-lb-create` - Create DigitalOcean load balancer
- `k8s-lb-configure` - Configure HTTPS on load balancer
- `k8s-secrets` - Sync environment secrets to Kubernetes

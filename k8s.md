  Usage Example

  # 1. Build and push Docker image
  devops/bin/k8s-build --app platform --version `sem-info tag latest` --push

  # 2. Sync secrets to Kubernetes
  devops/bin/k8s-secrets --app platform --apply

  # 3. Run database migrations
  devops/bin/k8s-migrate --app platform --version `sem-info tag latest` --wait

  # 4. Deploy to Kubernetes
  devops/bin/k8s-deploy --app platform --version `sem-info tag latest` --wait


Deployment Workflow (New)

 # 1. Build and push app image
 ./bin/k8s-build --app platform

 # 2. Sync secrets from git-crypt to K8s
 ./bin/k8s-secrets --app platform

 # 3. Run database migrations (if schema changes)
 ./bin/k8s-migrate --app platform

 # 4. Deploy to Kubernetes
 ./bin/k8s-deploy --app platform --version 0.7.41

 # 5. Check status
 ./bin/k8s-status --app platform

 # 6. Rollback if needed
 ./bin/k8s-rollback --app platform

 Local development (unchanged):
 # Secrets from git-crypt
 cd ~/code/env && git-crypt unlock
 source apps/platform/env/common.env
 source apps/platform/env/development.env

 # Run migrations locally
 cd ~/code/platform-postgresql && ./dev.rb

 # Run app
 cd ~/code/platform && sbt run
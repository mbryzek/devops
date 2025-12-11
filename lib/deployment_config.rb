# Shared configuration constants for deployment operations
module DeploymentConfig
  # Time to wait after removing from LB for connections to close
  DRAIN_WAIT_SECONDS = 10

  # Maximum times to poll healthcheck before failing
  HEALTHCHECK_MAX_RETRIES = 25

  # Max time to wait for LB removal confirmation
  LB_REMOVAL_POLL_TIMEOUT = 30
end

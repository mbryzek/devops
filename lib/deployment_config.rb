# Shared configuration constants for deployment operations
module DeploymentConfig
  # Time (in seconds) to wait after POSTing to instance's /_internal_/drain endpoint.
  # This gives DigitalOcean time to detect the node is unhealthy via healthcheck
  # while the instance continues to serve traffic.
  INSTANCE_DRAIN_WAIT_SECONDS = 15

  # Time (in seconds) to wait after removing from LB for connections to drain completely.
  # This allows in-flight requests to complete before killing the process.
  DRAIN_WAIT_SECONDS = 10

  # Maximum number of healthcheck polls (including the initial attempt) before failing.
  # Each poll waits 1 second, so default timeout is approximately 25 seconds.
  HEALTHCHECK_MAX_POLLS = 25

  # Maximum time (in seconds) to wait for confirmation that node was removed from LB.
  # Prevents infinite polling if LB API is unresponsive.
  LB_REMOVAL_POLL_TIMEOUT = 30
end

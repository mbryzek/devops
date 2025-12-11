Goal: True zero downtime deploys of scala applications

Constraints:
  - load balancer updates trigger short downtime
  - Goal: Avoid depending on load balancer
  - Scala applications each run on unique ports

We have 3 nodes in production to which we can deploy
We have 2 scala applications - acumen and platform
Desired end state:
  - each application is running on 2 nodes
  - each application's job instance requires more ram and is the only app running on one node

Example:
  - Node 1: acumen jobs
  - Node 2: platform jobs
  - Node 3: acumen and platform instances (not job)

Strategy:
  - When starting a deployment, 1st collect data from production to see what is running:
    - https://api.trueacumen.com/_internal_/healthcheck
      {"status":"healthy","module":"production","job_server":true}
  - Then build a deployment plan for the application
    - preference to deploy job instance of the application LAST

Because of the load balancer constraint, we need to find a strategy where we can deploy to a node that is not currently using the application port.

Example:

User initiates deploy of acumen (port 9200). platform is port 9300

Find current state:
  - Node 1: acumen jobs
  - Node 2: platform jobs
  - Node 3: acumen and platform instances (not job)

The only node available to install port 9200 is Node 2. Build Plan:

  - deploy acumen to node 2
  - when healthy, drain node 3 instance
  - when drained, deploy to node 3
  - when healthy, drain node1 instance
  - deploy to node 1 (as job instance)
  - when healthy, drain node 2
  - when drained, stop node 2

The end result is we "borrowed" node 2 during the deploy to maintain uptime. End state for platform is unchanged.
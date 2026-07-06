require 'set'

module Codegen
  class Graph
    attr_reader :backends, :consumers

    def initialize(backends:, consumers:, edges:)
      @backends = backends
      @consumers = consumers
      @edges = edges # consumer name => [backend names]
    end

    def depends_on(consumer)
      @edges.fetch(consumer, [])
    end

    # Roles come from STACK, not generator keys: scala repos are backends (they
    # upload specs to the shared registry), everything else is a consumer that
    # only regenerates a client. A consumer depends on a backend when their
    # configs share an apibuilder app name — i.e. the consumer regenerates a
    # client for something the backend declares. This is a conservative superset
    # (if two backends ever declared the same app name, a consumer of it would
    # depend on both): it only ever ADDS an ordering/gating edge, never drops
    # one, so it cannot reintroduce the missing-edge bug a generator-key
    # allowlist did.
    def self.build(apps:, configs:)
      eligible = apps.reject(&:ignored).select { |a| configs.key?(a.name) }
      backends = eligible.select { |a| a.stack == :scala }.map(&:name).sort
      backend_apps = backends.each_with_object({}) do |b, h|
        h[b] = configs.fetch(b).app_names
      end
      consumers = (eligible.map(&:name) - backends).sort
      edges = consumers.each_with_object({}) do |c, h|
        wants = configs.fetch(c).app_names
        h[c] = backends.select { |b| wants.intersect?(backend_apps[b]) }.sort
      end
      new(backends: backends, consumers: consumers, edges: edges)
    end
  end
end

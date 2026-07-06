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

    def self.build(apps:, configs:)
      eligible = apps.reject(&:ignored).select { |a| configs.key?(a.name) }
      backends = eligible.select { |a| a.stack == :scala }.map(&:name).sort
      produced = backends.each_with_object({}) do |b, h|
        h[b] = configs.fetch(b).produced_names
      end
      consumers = (eligible.map(&:name) - backends).sort
      edges = consumers.each_with_object({}) do |c, h|
        wants = configs.fetch(c).consumed_names
        h[c] = backends.select { |b| wants.intersect?(produced[b]) }.sort
      end
      new(backends: backends, consumers: consumers, edges: edges)
    end
  end
end

require 'json'

# Global node pool from nodes.pkl
# Actual app assignments come from DigitalOcean tags at runtime
class NodePool
    DIR = File.dirname(__FILE__)
    POOL_JSON_PATH = File.join(DIR, "../dist/nodes.config.json")

    def initialize
        gen_json = File.join(DIR, "../generate-json.rb")
        Util.run("#{gen_json} -q", :quiet => true) if File.exist?(gen_json)

        if !File.exist?(POOL_JSON_PATH)
            Util.exit_with_error("Node pool config not found at #{POOL_JSON_PATH}")
        end

        @pool = JSON.parse(IO.read(POOL_JSON_PATH))
    end

    # Returns job-capable nodes (role: "jobs")
    def job_nodes
        @pool['nodes'].select { |n| n['role'] == 'jobs' }.map { |n| n['uri'] }
    end

    # Returns shared API node (role: "shared")
    def shared_node
        @pool['nodes'].find { |n| n['role'] == 'shared' }&.dig('uri')
    end

    # All node URIs
    def all_uris
        @pool['nodes'].map { |n| n['uri'] }
    end
end

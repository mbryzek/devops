class RunScript

    def initialize(config, file, vars, index)
        @config = config
        @file = file
        @vars = RunScript.with_deployment_node_index(vars, index)
    end

    def RunScript.with_deployment_node_index(vars, index)
        vars.with_variable("DEPLOYMENT_NODE_INDEX", index.to_s)
    end

    def to_file(name, index)
        dir = File.basename(@file).sub(/\.tar\.gz$/, "")

        env = RunScript.with_deployment_node_index(@vars, index)
        File.open(name, "w") do |out|
          out << "#!/usr/bin/env sh\n\n"
          out << "#{env.serialize("sh")} bin/#{@config.scala.dist_run_script_name} \"-Dhttp.port=#{@config.port}\"\n"
        end
        Util.run("chmod +x #{name}")
        nil
    end
end

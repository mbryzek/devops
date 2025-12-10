class RunScript

  attr_reader :vars

  def initialize(config, file, vars, nodes, index)
    @config = config
    @file = file
    @node = nodes[index]
    port_string = config.port == 80 ? '' : ":#{config.port}"
    all_nodes = nodes.map { |n| "#{n.uri}#{port_string}" }
    @vars = vars.with_variable("DEPLOYMENT_NODE_INDEX", index.to_s).with_variable("DEPLOYMENT_NODES", all_nodes.join(","))
  end

  def to_file(name)
    memory = @node.job_server? ? @config.scala.memory.job_server : @config.scala.memory.default
    java_opts = "-Xms#{memory} -Xmx#{memory} -XX:+HeapDumpOnOutOfMemoryError -XX:HeapDumpPath=/tmp/ -XX:+ExitOnOutOfMemoryError"

    File.open(name, "w") do |out|
      out << "#!/usr/bin/env sh\n\n"
      out << "JAVA_OPTS='#{java_opts}' #{@vars.serialize("sh")} bin/#{@config.scala.dist_run_script_name} \"-Dhttp.port=#{@config.port}\"\n"
    end
    Util.run("chmod +x #{name}")
    nil
  end
end

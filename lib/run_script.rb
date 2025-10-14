class RunScript

  attr_reader :vars

  def initialize(config, file, vars, nodes, index)
    @config = config
    raise config.inspect
    @file = file
    all_nodes = nodes.map { |n| "#{n.uri}" }
    @vars = vars.with_variable("DEPLOYMENT_NODE_INDEX", index.to_s).with_variable("DEPLOYMENT_NODES", all_nodes.join(","))
  end

  def to_file(name)
    File.open(name, "w") do |out|
      out << "#!/usr/bin/env sh\n\n"
      out << "#{@vars.serialize("sh")} bin/#{@config.scala.dist_run_script_name} \"-Dhttp.port=#{@config.port}\"\n"
    end
    Util.run("chmod +x #{name}")
    nil
  end
end

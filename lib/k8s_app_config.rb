# The per-app deploy config in `k8s/apps/<app>.pkl`: the fields the
# scala-play-app template is rendered with (webMemory, jobMemory, javaAgent,
# distributedTracing), read once, here.
#
# It existed inline in bin/k8s-deploy as three lines, and the third of them was
# a silent failure:
#
#     config_output = `cd #{K8S_DIR} && pkl eval -f json apps/#{app}.pkl 2>/dev/null`
#     config = JSON.parse(config_output) rescue {}
#
# `2>/dev/null` discards pkl's diagnostics and `rescue {}` turns ANY failure —
# a syntax error in the app config, a pkl binary that is not installed, a
# misspelled app name — into an empty hash. An empty hash has no `javaAgent`,
# so the manifest renders with no `-javaagent` flag and the deploy SUCCEEDS,
# having quietly shipped the app with its APM instrumentation removed. Nothing
# in the output says so, and the only symptom is that an app stops reporting to
# New Relic, which looks exactly like an app with no errors (ISS-1070).
#
# So every failure here is loud, and the four are distinguished because they
# call for different fixes: no such app config, pkl not installed, pkl refused
# to evaluate, pkl emitted something that is not an object.
module K8sAppConfig
  # k8s/ is a sibling of lib/, and pkl resolves the template's `import` lines
  # relative to the directory it evaluates from — hence the chdir rather than an
  # absolute path to the file.
  DIR = File.expand_path("../k8s", __dir__)

  def self.path(app)
    File.join(DIR, "apps", "#{app}.pkl")
  end

  # Whether this app's manifests are rendered from k8s/templates/scala-play-app.pkl
  # — i.e. whether it has a `k8s/apps/<app>.pkl` at all.
  #
  # A `docker_k8s` app does not: it ships hand-written manifests under
  # k8s/manifests/<app>/ (today only `workers`, a Node service — templating one
  # app isn't a win), so there is nothing for `load` to read and no javaAgent for
  # anything to honor.
  #
  # The test is the app's own deploy shape rather than "the pkl file happens to
  # be missing" ON PURPOSE. File-absence is exactly the condition `load` exists
  # to shout about: a scala-play app whose config is deleted or misspelled must
  # still abort, because an empty config has no javaAgent and would ship the app
  # silently un-instrumented (ISS-1070). Keying off docker_k8s exempts the apps
  # that never had a config without also exempting the ones that lost theirs.
  def self.template_rendered?(app_config)
    app_config.docker_k8s.nil?
  end

  # The app's deploy config as a Hash. Aborts rather than returning a partial
  # or empty one; see the header for why an empty hash is the dangerous answer.
  def self.load(app)
    file = path(app)
    unless File.exist?(file)
      available = Dir.glob(File.join(DIR, "apps", "*.pkl")).map { |f| File.basename(f, ".pkl") }.sort
      Util.exit_with_error("No k8s app config for '#{app}' at #{file}. Available: #{available.join(', ')}")
    end

    output = `cd #{DIR} && pkl eval -f json apps/#{app}.pkl 2>&1`
    unless $?.success?
      if output.include?("pkl: command not found") || output.include?("pkl: not found")
        Util.exit_with_error("pkl is not installed, so #{app}'s deploy config cannot be read. Install it: brew install pkl")
      end
      Util.exit_with_error("pkl could not evaluate #{file}:\n#{output}")
    end

    config = begin
      JSON.parse(output)
    rescue JSON::ParserError => e
      Util.exit_with_error("pkl emitted invalid JSON for #{file} (#{e.message}):\n#{output}")
    end

    unless config.is_a?(Hash)
      Util.exit_with_error("Expected an object from #{file}, got #{config.class}")
    end

    config
  end

  # True when this app is deployed with a JVM agent attached — in practice the
  # New Relic APM agent, which templates/Dockerfile.scala-play bakes into EVERY
  # scala-play image. The jar being present is therefore not evidence that an
  # app is instrumented; this field is.
  def self.java_agent?(config)
    !config["javaAgent"].to_s.strip.empty?
  end

  # The one secret an attached New Relic agent cannot start without. Named here
  # rather than in each caller so the guard and its error message cannot drift
  # apart from what k8s-secrets actually syncs.
  LICENSE_KEY = "NEW_RELIC_LICENSE_KEY".freeze
end

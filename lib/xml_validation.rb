require 'rexml/document'

# Parses the XML config files baked into a built distribution.
#
# Nothing else in the pipeline reads these files. sbt does not parse them, the
# Docker build only copies them, and the rollout only learns they are broken
# when logback reads conf/logback.xml during slf4j initialization — which
# happens before Play starts, so a malformed file means every pod
# CrashLoopBackOffs. That surfaces ~6 minutes into the rollout, long after the
# image has been pushed to the registry under a tag that never moves again.
#
# platform 0.18.84 shipped a bare "--" inside a logback comment (illegal in XML)
# and took platform-job down for two hours. Parsing here turns that into a build
# failure, before the push.
module XmlValidation
  # Returns a list of human-readable error strings, one per unparseable file.
  # Empty means every file parsed.
  def self.errors_in(files)
    files.filter_map do |file|
      begin
        REXML::Document.new(File.read(file))
        nil
      rescue REXML::ParseException => e
        "#{file}: #{e.message.lines.first.to_s.strip}"
      end
    end
  end

  # Every XML config file in an extracted distribution directory.
  def self.config_files(dist_dir)
    Dir.glob(File.join(dist_dir, "conf/**/*.xml")).sort
  end
end

#!/usr/bin/env ruby

load File.join(File.dirname(__FILE__), '../lib/common.rb')

app = Config.from_args(ARGV)

KEEP_N_RELEASES = 2

class Version
  include Comparable

  attr_reader :major, :minor, :micro

  def initialize(major, minor, micro)
    @major = major.to_i
    @minor = minor.to_i
    @micro = micro.to_i
  end

  def tag
    to_array.join(".")
  end

  def to_array
    [major, minor, micro]
  end

  def <=>(other)
    to_array <=> other.to_array
  end

  def Version.parse(value)
    all = value.split(/\./, 3)
    if all.length == 3 && all.all? { |i| i.to_i.to_s == i }
      Version.new(all[0], all[1], all[2])
    else
      nil
    end
  end
end

class Release

  attr_reader :path, :app, :version

  def initialize(path, app, version)
    @path = path
    @app = app
    @version = version
  end
end

IGNORED = ["run.sh", "api-run.sh", "acumen-api-run.sh"]
def delete_old(app)
  all = Dir.glob("#{app}*").map { |f|
    name = File.basename(f).sub(/\.tar.gz$/, '').sub(/\.tar$/, '')
    next if IGNORED.include?(name)
    app, tag = name.sub(/\-postgresql/, '').split(/-/, 2)
    if app.nil? || tag.nil?
      nil
    elsif v = Version.parse(tag)
      Release.new(f, app, v)
    else
      puts " ** WARNING[#{f}] Could not parse version from '#{tag}' - skipping"
      nil
    end
  }.filter { |v| !v.nil? }

  all.group_by(&:app).map do |app, releases|
    sorted = releases.sort_by { |r| r.version }
    all_versions = sorted.map { |r| r.version.tag }.uniq
    to_delete = all_versions.reverse.drop(KEEP_N_RELEASES).reverse
    if !to_delete.empty?
      puts " - %s: Deleting versions %s" % [app, to_delete.join(", ")]
      sorted.filter { |r| to_delete.include?(r.version.tag) }.each { |r|
        Util.run("rm -rf #{r.path}")
      }
    end
  end
end

delete_old(app.name)

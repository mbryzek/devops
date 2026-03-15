require 'fileutils'

module ApibuilderFileWriter
  def self.write_code_files(code, target_dir)
    (code["files"] || []).each do |file|
      dir = file["dir"] ? File.join(target_dir, file["dir"]) : target_dir
      FileUtils.mkdir_p(dir)
      path = File.join(dir, file["name"])
      IO.write(path, file["contents"])
      puts "  wrote #{path}"
    end
  end
end

require 'fileutils'
require 'tmpdir'

module ApibuilderFileWriter

  # Lines matching these patterns are ignored when comparing files
  IGNORE_PATTERNS = [
    /^\s*\*\s*Service version:/,
    /^\s*\*\s*User agent:/,
    /^\s*\*\s*apibuilder app/,
  ]

  # Stages code files into a temporary directory.
  # Returns an array of [src_path, dest_path] pairs.
  def self.stage_code_files(code, target_dir, tmp_dir)
    pairs = []
    (code["files"] || []).each do |file|
      dest_dir = file["dir"] ? File.join(target_dir, file["dir"]) : target_dir
      dest_path = File.join(dest_dir, file["name"])

      tmp_file_dir = File.join(tmp_dir, dest_dir)
      FileUtils.mkdir_p(tmp_file_dir)
      tmp_path = File.join(tmp_file_dir, file["name"])
      IO.write(tmp_path, file["contents"])

      pairs << [tmp_path, dest_path]
    end
    pairs
  end

  # Copies staged files into their final destinations, skipping files
  # that haven't meaningfully changed (ignoring apibuilder comment metadata).
  def self.flush(pairs)
    written = 0
    skipped = 0
    pairs.each do |src, dest|
      if File.exist?(dest) && !meaningful_change?(src, dest)
        skipped += 1
      else
        FileUtils.mkdir_p(File.dirname(dest))
        FileUtils.cp(src, dest)
        puts "  wrote #{dest}"
        written += 1
      end
    end
    puts "  #{written} written, #{skipped} unchanged" if skipped > 0
  end

  private

  def self.meaningful_change?(new_path, existing_path)
    strip_metadata(IO.read(new_path)) != strip_metadata(IO.read(existing_path))
  end

  def self.strip_metadata(content)
    content.each_line.reject { |line| IGNORE_PATTERNS.any? { |p| p.match?(line) } }.join
  end

end

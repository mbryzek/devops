require 'pathname'

module Util
    def Util.run(cmd, params={})
      quiet = (params.has_key?(:quiet) && params[:quiet]) ? true  : false
      ignore_error = (params.has_key?(:ignore_error) && params[:ignore_error]) ? true : false
      if !quiet
          puts "==> #{cmd}"
      end
      if !system(cmd)
        if !ignore_error
          Util.exit_with_error("Command failed: #{cmd}")
        end
      end
    end

    def Util.exit_with_error(msg)
        puts ""
        puts "ERROR: #{msg}"
        puts ""
        exit 1
    end

    def Util.indent(text, size = 2)
      indent = ' ' * size
      text.split("\n").map { |line| indent + line }.join("\n")
    end

    def Util.underline(text)
        "#{text}\n#{'=' * text.length}"
    end

    def Util.installed?(cmd)
      system("which #{cmd} > /dev/null 2>&1") ? true : false
    end

    def Util.cleanpath(path)
        Pathname.new(path).cleanpath
    end

    def Util.warning(text)
        puts ""
        puts ('*') * 100
        puts Util.indent("WARNING: " + text)
        puts ('*') * 100
    end

    def Util.read_file(path)
      full_path = File.expand_path(path)
      if !File.exist?(full_path)
        Util.exit_with_error("Cannot find file #{full_path}")
      end
      IO.read(full_path).strip
    end

    def Util.assert_installed(cmd, url=nil)
      if !system("which %s > /dev/null" % cmd)
        msg = "Please install %s" % cmd
        if url
          msg += " (%s)" % url
        end
        Util.exit_with_error(msg)
      end
    end
    
    def Util.assert_sem_installed
      Util.assert_installed("sem-info", "https://github.com/mbryzek/schema-evolution-manager")
    end
end

class DevopsConfigFile
    FILE = ".devops/config"

    attr_reader :apibuilder_organization
    def initialize(apibuilder_organization)
        @apibuilder_organization = apibuilder_organization
    end

    def DevopsConfigFile.default_path
        File.join(`pwd`.strip, ".devops", "config")
    end

    def DevopsConfigFile.load(path = default_path)
        if !File.exist?(path)
            Util.exit_with_error("Devops config file not found at #{path}")
        end

        apibuilder_organization = nil
        IO.readlines(path).each do |l|
            if l.strip.empty? || l.strip.start_with?("#")
                next
            end
            key, value = l.strip.split("=", 2)
            case key
            when "apibuilder_organization"
                apibuilder_organization = value
            end
        end

        if apibuilder_organization.nil?
            Util.exit_with_error("apibuilder_organization not set in #{path}")
        end

        DevopsConfigFile.new(apibuilder_organization)
    end
end

class CodegenConfig

    def initialize(project_name)
        @project_name = project_name
    end

    def is_hoa?
        @project_name == "hoa-frontend"
    end

    def is_acumen?
        @project_name == "acumen-ui"
    end

end

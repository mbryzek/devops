class GlobalState

  ANONYMOUS = "GlobalStateAnonymousData"
  AUTHENTICATED = "GlobalStateAuthenticatedData"
  GROUP = "GlobalStateGroupData"
  SUBSCRIBER = "GlobalStateSubscriberData"
  GAME = "GameGlobalState"
  ALL = [ANONYMOUS, AUTHENTICATED, SUBSCRIBER, GROUP, GAME]

  def GlobalState.from_name(name)
    if n = ALL.find { |a| a == name }
      GlobalState.new(n)
    else
      nil
    end
  end

  def GlobalState.assert_unique(file, states)
    names = states.map(&:name).uniq.sort
    if names.size > 1
      Util.exit_with_error("File #{file}: Multiple global states found: #{names.join(", ")}")
    end
    states.first
  end

  attr_reader :name
  def initialize(name)
    @name = name
  end

  def requires_login?
    @name == AUTHENTICATED
  end

  def requires_group?
    @name == GROUP
  end

  def requires_subscriber?
    @name == SUBSCRIBER
  end

  def requires_game?
    @name == GAME
  end

  def requires_anonymous?
    @name == ANONYMOUS
  end
end

# Parse the init function for the page
class ElmDeclaration

  attr_reader :args, :returns, :global_state

  # returns: e.g. ["Model", "Cmd Msg"]
  def initialize(file, args, returns)
    @file = file
    @args = args
    @returns = returns
    @global_state = parse_global_state(args)
  end

  def ElmDeclaration.parse(file, lines, keyword)
    if line = lines.find { |l| l.strip.match(/^#{keyword}\s*\:/) }
      ElmDeclaration.parse_line(file, line)
    else
      nil
    end
  end

  def ElmDeclaration.parse_line(file, line)
    parts = line.sub(/\:/, "->").split("->").drop(1).map(&:strip)
    returns = strip_parens(parts.last).split(",").map(&:strip)
    args = parts.reverse.drop(1).reverse
    if returns.empty?
      raise "Failed to parse return type from line: #{line.inspect}"
    end
    ElmDeclaration.new(file, args, returns)
  end

  def ElmDeclaration.strip_parens(s)
    if s.start_with?("(") && s.end_with?(")")
      s[1..-2]
    else
      s
    end
  end

  private
  def parse_global_state(args)
    states = args.map do |arg|
      name, rest = arg.split(" ")
      GlobalState.from_name(name)
    end.filter { |s| s }.uniq

    GlobalState.assert_unique(@file, states)
  end 
end

class ElmMsg
    attr_reader :name
    def initialize(name)
        @name = name
    end

    def ElmMsg.from_module_name(lines)
      name = ElmFile.parse_module_name(lines).gsub(/\./, '') + "Msg"
      ElmMsg.new(name)
  end

  def ElmMsg.from_module_name_alias(lines)
    name = ElmFile.parse_module_name(lines).gsub(/\./, '') + "Msg"
    ElmMsg.new(name)
end

end

class ElmModel
  attr_reader :name
def initialize(name)
    @name = name
  end
end

class ElmModule
  attr_reader :name, :alias
  def initialize(name)
    @name = name
    @alias = name.gsub(/\./, '')
    @admin = @name.split(".").map(&:downcase).include?("admin")
  end

  def admin?
    @admin
  end
end

class ElmRoute
  attr_reader :name
  def initialize(name)
      @name = name
  end

  def ElmRoute.from_module_name(module_name)
      ElmRoute.new(module_name.sub(/^Page\./, "Route").gsub(/\./, ''))
  end
end


class ElmFile

    attr_reader :path, :module, :model, :msg, :route, :init, :update, :view, :subscriptions, :filters
 
    def initialize(path, module_name, model, msg, init, update, view, subscriptions)
      if !module_name.start_with?("Page.")
          raise "Expected module name '#{module_name}' to start with Page"
      end

      @path = path
      @module = ElmModule.new(module_name)
      @route = ElmRoute.from_module_name(module_name)
      @model = model
      @msg = msg
      @init = init
      @update = update
      @view = view
      @subscriptions = subscriptions
      @declarations = [@init, @update, @view].filter { |d| d }
      @comments = ElmCodeGenComments.read_file(path)
      @global_state = validate_global_state(@comments, @declarations)
      @filters = @comments.filters
      if requires_admin? && !requires_login?
        Util.exit_with_error("File #{@path}: Admin pages must also require login")
      end
    end

    def requires_admin?
      @module.admin?
    end

    def requires_login?
      @global_state.requires_login?
    end

    def requires_group?
      @global_state.requires_group?
    end

    def requires_subscriber?
      @global_state.requires_subscriber?
    end

    def requires_game?
      @global_state.requires_game?
    end

    def requires_anonymous?
      @global_state.requires_anonymous?
    end

    def ElmFile.parse(f)
        contents = File.read(f)
        lines = contents.split("\n")

        module_name = parse_module_name(lines)
        ElmFile.assert(f, module_name, "Failed to parse module name")

        init = ElmDeclaration.parse(f, lines, "init")
        update = ElmDeclaration.parse(f, lines, "update")
        view = ElmDeclaration.parse(f, lines, "view")
        subscriptions = ElmDeclaration.parse(f, lines, "subscriptions")
        model = contents.include?("type alias Model") ? ElmModel.new("Model") : nil
        msg = contents.include?("type Msg") ? ElmMsg.from_module_name(lines) : nil
        msg ||= contents.include?("type alias Msg") ? ElmMsg.from_module_name_alias(lines) : nil
        ElmFile.new(f, module_name, model, msg, init, update, view, subscriptions)
    end

    def ElmFile.raise_error(file, desc)
        raise "[#{file}] #{desc}"
    end

    private
    def validate_global_state(comments, declarations)
      states = declarations.map(&:global_state).compact.uniq
      states << comments.global_state if comments.global_state && !states.include?(comments.global_state)

      if states.empty?
        puts ""
        puts "File #{@path}: Could not determine global state. Please select and we will update the file:"
        global_state = Ask.select_from_list("Global state", GlobalState::ALL)
        gs = GlobalState.from_name(global_state)
        if gs.nil?
          raise "File[#{@path}]: Could not convert global state '#{global_state}' to a GlobalState object"
        end
        comments.set_global_state!(gs)
        gs

      else
        GlobalState.assert_unique(@path, states)
      end
    end

    def ElmFile.assert(file, value, desc)
        if value.nil?
            ElmFile.raise_error(file, desc)
        end
    end

    def ElmFile.parse_module_name(lines)
        line = lines.select { |l| !is_comment(l) && !is_empty(l) }.first.to_s
        if line.match(/^module /)
            line.split(/\s+/).drop(1).first
        else
            nil
        end
    end

    def ElmFile.is_comment(line)
        line.strip.match(/^--/)
    end

    def ElmFile.is_empty(line)
        line.strip.empty?
    end
end


class ElmCodeGenComments

  attr_reader :file, :global_state, :filters
  def initialize(file, global_state, filters)
    @file = file
    @global_state = global_state
    @filters = filters
  end

  def ElmCodeGenComments.read_file(file)
    lines = IO.readlines(file).select { |l| l.strip.match(/^-- codegen\./) }
    filters = []

    global_state = nil
    if !lines.empty?
      lines.map do |l|
        key, value = l.strip.sub(/\A-- codegen\./, "").split(":").map(&:strip)

        if key == "global.state"
          gs = GlobalState.from_name(value)
          if gs.nil?
            Util.exit_with_error("File #{file}: Unknown global state: #{value}")
          end
          if global_state
            Util.exit_with_error("File #{file}: Multiple codegen.global.state comments found")
          end
          global_state = gs

        elsif key == "filter.require_active_subscription"
          filters << "RequireActiveSubscription"

        else
          Util.exit_with_error("File #{file}: Unknown code gen attribute: #{key}")
        end
      end
    end

    ElmCodeGenComments.new(file, global_state, filters)
  end

  def set_global_state!(global_state)
    @global_state = global_state
    write_file!
  end

  private
  def write_file!
    contents = IO.readlines(file).select { |l| !l.strip.match(/^-- codegen\./) }

    File.open(file, "w") do |f|
      f << "-- codegen.global.state: #{global_state.name}\n" if @global_state
      f << contents.join("")
    end
  end

end
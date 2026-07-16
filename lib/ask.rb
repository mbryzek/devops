class Ask

  TRUE = ['y', 'yes']
  FALSE = ['n', 'no']
  ALL = ['all', 'a', '*']
  NONE = ['none', 'n', 'no', 'q', 'quit']

  def Ask.for_string(msg, opts={})
    default = opts.has_key?(:default) ? opts[:default].to_s.strip : nil
    prompt = default.nil? || msg.include?("[#{default}]")? msg : "#{msg} [#{default}]"
    hide_input = opts.has_key?(:hide_input) ? opts[:hide_input] : false
    value = ""
    while value.empty?
      puts prompt
      system("stty -echo") if hide_input
      value = STDIN.gets
      system("stty echo") if hide_input
      value.strip!
      if value.empty? && default
        value = default
      end
    end
    value
  end

  def Ask.for_boolean(msg)
    result = nil
    while result.nil?
      value = Ask.for_string(msg).downcase
      if TRUE.include?(value)
        result = true
      elsif FALSE.include?(value)
        result = false
      end
    end
    result
  end
  
  def Ask.for_positive_integer(message, opts={})
    value = Ask.for_string(message, opts).to_i
    if value > 0
      value
    else
      puts ""
      puts "Please enter a positive integer"
      Ask.for_positive_integer(message, opts)
    end
  end

  # Multi-select over `values`. Accepts 1-based indexes ("1,3" or "1 3"), `all`,
  # or `none`; empty input takes opts[:default] ("all" unless given). Returns the
  # selected subset, in list order. Re-prompts until the input parses.
  def Ask.select_multiple_from_list(message, values, opts={})
    default = opts.has_key?(:default) ? opts[:default].to_s : ALL.first
    labels = values.map.with_index { |v, i| "  #{i+1}. #{v}" }
    # The "[default]" marker is inline so for_string doesn't append its own after
    # the (multi-line) list, where it would read as belonging to the last item.
    prompt = "#{message}\n\n#{labels.join("\n")}\n\nEnter numbers (e.g. 1,3), `all`, or `none` [#{default}]:"
    loop do
      selected = Ask.parse_selection(Ask.for_string(prompt, default: default), values)
      return selected if selected
      puts ""
      puts "Invalid selection. Enter numbers between 1 and #{values.length} (e.g. 1,3), `all`, or `none`."
    end
  end

  # Parses one multi-select answer: the subset of `values` it names, or nil if
  # the input is unparseable (the caller re-prompts). Split from the prompt loop
  # so the accepted forms are testable without stdin.
  def Ask.parse_selection(raw, values)
    s = raw.to_s.strip.downcase
    return values.dup if ALL.include?(s)
    return [] if NONE.include?(s)

    tokens = s.split(/[\s,]+/).reject(&:empty?)
    return nil if tokens.empty?
    return nil unless tokens.all? { |t| t.match?(/\A\d+\z/) }
    indexes = tokens.map(&:to_i)
    return nil unless indexes.all? { |i| i >= 1 && i <= values.length }
    indexes.uniq.sort.map { |i| values[i - 1] }
  end

  def Ask.select_from_list(message, values, opts={})
    default = opts.has_key?(:default) ? opts[:default] : nil
    labels = values.map.with_index do |v, i|
      "  #{i+1}. #{v}"
    end
    m = default.nil? ? message : "#{message} [#{default}]"
    i = Ask.for_positive_integer("#{m}\n\n#{labels.join("\n")}", opts)
    puts "value: #{i}"
    if v = values[i-1]
      v
    else
      puts ""
      puts "Invalid selection"
      Ask.select_from_list(message, values, opts)
    end
  end
end
  

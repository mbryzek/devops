class Ask

  TRUE = ['y', 'yes']
  FALSE = ['n', 'no']
  
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
  

require 'parser/current'

class Processor < AST::Processor

  def warnings?
    warnings.any?
  end

  def warnings
    @warnings ||= []
  end

  def add_warning(w)
    warnings << w
  end

  def on_begin(node)
    node.children.each { |c| process(c) }
  end

  def handler_missing(node)
    # puts "missing #{node.type}"
  end

  def on_def(node)
    line_num    = node.loc.line
    method_name = node.children[0]
  end

  def on_defs(node)
    line_num    = node.loc.line
    method_name = node.children[0]
  end

  def on_send(node)
    line_num    = node.loc.line
    method_name = node.children[0]

    node.children.each { |c| process(c) if c.class == Parser::AST::Node }

    attributes = node
      .children
      .select { |child| child.class == Parser::AST::Node }
      .map { |c| c.children }

    # FIND_OR_CREATE_BY RULE
    if node.children[1] && node.children[1].to_s.include?('find_or_create_by_')
      add_warning("Found #{node.children[1].to_s} at line #{line_num}. Replace it with find_or_create_by(...) instead.")
    end

    # FIND_OR_INITIALIZE_BY RULE
    if node.children[1] && node.children[1].to_s.include?('find_or_initialize_by_')
      add_warning("Found #{node.children[1].to_s} at line #{line_num}. Replace it with find_or_initialize_by(...) instead.")
    end

    # SCOPED_BY RULE
    if node.children[1] && node.children[1].to_s.include?('scoped_by_')
      add_warning("Found #{node.children[1].to_s} at line #{line_num}. Replace it with where(...) instead.")
    end

    # FIND_LAST_BY RULE
    if node.children[1] && node.children[1].to_s.include?('find_last_by_')
      add_warning("Found #{node.children[1].to_s} at line #{line_num}. Replace it with where(...).last instead.")
    end

    # FIND_ALL_BY RULE
    if node.children[1] && node.children[1].to_s.include?('find_all_by_')
      add_warning("Found #{node.children[1].to_s} at line #{line_num}. Replace it with where(...) instead.")
    end

    # ATTR ACCESIBLE RULE
    if node.children[1] && node.children[1] == :attr_accessible
      add_warning("Found attr_accessible with symbols #{attributes.join(', ')} at line #{line_num}. Replace it with strong parameters instead.")
    end

    # ATTR_PROTECTED RULE
    if node.children[1] && node.children[1] == :attr_protected
      add_warning("Found attr_protected with symbols #{attributes.join(', ')} at line #{line_num}. Replace it with strong parameters instead.")
    end
  end



  def on_block(node)
    node.children.each { |c| process(c) if c.class == Parser::AST::Node }
  end
  alias :on_casgn :on_block
  alias :on_if :on_block
  alias :on_lvasgn :on_block
  alias :on_class :on_block
  alias :on_const :on_block
  alias :on_class :on_block
  alias :on_module :on_block
  alias :on_lvar :on_block
  alias :ivasgn :on_block
end






puts '*-' * 67
puts <<-STR



      .______   .______       _______     ___       _______   ______ .______       __    __  .___  ___. .______        _______.
      |   _  \\  |   _  \\     |   ____|   /   \\     |       \\ /      ||   _  \\     |  |  |  | |   \\/   | |   _  \\      /       |
      |  |_)  | |  |_)  |    |  |__     /  ^  \\    |  .--.  |  ,----'|  |_)  |    |  |  |  | |  \\  /  | |  |_)  |    |   (----`
      |   _  <  |      /     |   __|   /  /_\\  \\   |  |  |  |  |     |      /     |  |  |  | |  |\\/|  | |   _  <      \\   \\
      |  |_)  | |  |\\  \\----.|  |____ /  _____  \\  |  '--'  |  `----.|  |\\  \\----.|  `--'  | |  |  |  | |  |_)  | .----)   |
      |______/  | _| `._____||_______/__/     \\__\\ |_______/ \\______|| _| `._____| \\______/  |__|  |__| |______/  |_______/

      .__   __.   ______   .___  ___.        .__   __.   ______   .___  ___.        .__   __.   ______   .___  ___.
      |  \\ |  |  /  __  \\  |   \\/   |        |  \\ |  |  /  __  \\  |   \\/   |        |  \\ |  |  /  __  \\  |   \\/   |
      |   \\|  | |  |  |  | |  \\  /  |  ______|   \\|  | |  |  |  | |  \\  /  |  ______|   \\|  | |  |  |  | |  \\  /  |
      |  . `  | |  |  |  | |  |\\/|  | |______|  . `  | |  |  |  | |  |\\/|  | |______|  . `  | |  |  |  | |  |\\/|  |
      |  |\\   | |  `--'  | |  |  |  |        |  |\\   | |  `--'  | |  |  |  |        |  |\\   | |  `--'  | |  |  |  |
      |__| \\__|  \\______/  |__|  |__|        |__| \\__|  \\______/  |__|  |__|        |__| \\__|  \\______/  |__|  |__|




STR
puts '*-' * 67

files = Dir["#{ARGV[0]}/**/*.{rb,rake}"]
files.each do |file|
  ast = Processor.new
  file_text = File.read(file)
  parsed_code = Parser::CurrentRuby.parse(file_text)
  ast.process(parsed_code)
  if ast.warnings?
    puts '----' * 40
    puts "#{file} has #{ast.warnings.size} warnings"
    puts '----' * 40
    puts ast.warnings.join("\n")
    puts "\n"
  end
end

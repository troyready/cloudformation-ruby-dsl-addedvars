unless RUBY_VERSION >= '1.9'
  # This script uses Ruby 1.9 functions such as Enumerable.slice_before and Enumerable.chunk
  $stderr.puts "This script requires ruby 1.9+.  On OS/X use Homebrew to install ruby 1.9:"
  $stderr.puts "  brew install ruby"
  exit(2)
end

require 'rubygems'
require 'csv'
require 'json'
require 'yaml'
require 'erb'

############################# Command-line and "cfn-cmd" Support

# Parse command-line arguments based on cfn-cmd syntax (cfn-create-stack etc.) and return the parameters and region
def cfn_parse_args()
  parameters = {}
  region = 'us-east-1'
  stack_name = ARGV[1] && !(/^-/ =~ ARGV[1]) ? ARGV[1] : '<stack-name>'
  ARGV.slice_before(/^--/).each do |name, value|
    if name == '--parameters' && value
      parameters = Hash[value.split(/;/).map { |s| s.split(/=/, 2) }]
    elsif name == '--region' && value
      region = value
    end
  end
  [parameters, region, stack_name]
end

def cfn_cmd(template)
  unless %w(expand diff cfn-validate-template cfn-create-stack cfn-update-stack).include?(ARGV[0])
    $stderr.puts "usage: #{$PROGRAM_NAME} <expand|diff|cfn-validate-template|cfn-create-stack|cfn-update-stack>"
    exit(2)
  end
  unless (ARGV & %w(--template-file --template-url)).empty?
    $stderr.puts "#{File.basename($PROGRAM_NAME)}:  The --template-file and --template-url command-line options are not allowed."
    exit(2)
  end

  template_string = JSON.pretty_generate(template)
  if ARGV[0] == 'expand'
    # Write the pretty-printed JSON template to stdout.
    # example: <template.rb> expand --parameters "Universe=cert" --region eu-west-1
    puts template_string

  elsif ARGV[0] == 'diff'
    # example: <template.rb> diff my-stack-name --parameters "Universe=cert" --region eu-west-1
    # Diff the current template for an existing stack with the expansion of this template.
    cfn_options, diff_options = extract_options(ARGV[1..-1], %w(),
      %w(--stack-name --region --parameters --connection-timeout --delimiter -I --access-key-id -S --secret-key -K --ec2-private-key-file-path -U --url))
    # If the first argument is a stack name then shift it from diff_options over to cfn_options.
    if diff_options[0] && !(/^-/ =~ diff_options[0])
      cfn_options.unshift(diff_options.shift)
    end

    # Run CloudFormation commands to describe the existing stack
    _, cfn_options = extract_options(cfn_options, %w(), %w(--parameters))
    cfn_options_string = cfn_options.map { |arg| "'#{arg}'" }.join(' ')
    old_template_string = `cfn-cmd cfn-get-template #{cfn_options_string}`
    exit(false) unless $?.success?
    old_stack_description = `cfn-cmd cfn-describe-stacks #{cfn_options_string} --show-long`
    exit(false) unless $?.success?
    old_parameters_string = CSV.parse_line(old_stack_description)[6]

    # Sort the parameters strings alphabetically to make them easily comparable
    old_parameters_string = (old_parameters_string || '').split(';').sort.join(';')
    parameters_string = template.parameters.map { |k, v| k + '=' + v.to_s }.sort.join(';')

    # Diff the expanded template with the template from CloudFormation.
    old_temp_file = write_temp_file($PROGRAM_NAME, 'current.json', %Q(PARAMETERS "#{old_parameters_string}"\n#{old_template_string}))
    new_temp_file = write_temp_file($PROGRAM_NAME, 'expanded.json', %Q(PARAMETERS "#{parameters_string}"\nTEMPLATE  "#{template_string}\n"\n))

    system(*["diff"] + diff_options + [old_temp_file, new_temp_file])

    File.delete(old_temp_file)
    File.delete(new_temp_file)

  else
    # example: <template.rb> cfn-create-stack my-stack-name --parameters "Universe=cert" --region eu-west-1
    # Execute the AWS CLI cfn-cmd command to validate/create/update a CloudFormation stack.
    temp_file = write_temp_file($PROGRAM_NAME, 'expanded.json', template_string)

    cmdline = ['cfn-cmd'] + ARGV + ['--template-file', temp_file]

    # The cfn-validate-template command doesn't support --parameters so remove it if it was provided for template expansion.
    if ARGV[0] == 'cfn-validate-template'
      _, cmdline = extract_options(cmdline, %w(), %w(--parameters))
    end

    unless system(*cmdline)
      $stderr.puts "\nExecution of 'cfn-cmd' failed.  To facilitate debugging, the generated JSON template " +
                       "file was not deleted.  You may delete the file manually if it isn't needed: #{temp_file}"
      exit(false)
    end

    File.delete(temp_file)
  end

  exit(true)
end

def write_temp_file(name, suffix, content)
  path = File.absolute_path("#{name}.#{suffix}")
  File.open(path, 'w') { |f| f.write content }
  path
end

def extract_options(args, opts_no_val, opts_1_val)
  args = args.clone
  opts = []
  rest = []
  while (arg = args.shift) != nil
    if opts_no_val.include?(arg)
      opts.push(arg)
    elsif opts_1_val.include?(arg)
      opts.push(arg)
      opts.push(arg) if (arg = args.shift) != nil
    else
      rest.push(arg)
    end
  end
  [opts, rest]
end

############################# Generic DSL

class JsonObjectDSL
  def initialize(&block)
    @dict = {}
    instance_eval &block
  end

  def value(values)
    @dict.update(values)
  end

  def default(key, value)
    @dict[key] ||= value
  end

  def compact!()
    remove_nil(@dict)
  end

  def to_json(*args)
    compact!
    @dict.to_json(*args)
  end

  def print()
    puts JSON.pretty_generate(self)
  end
end

# In general, eliminate nil values.  If you really need it, create a wrapper class like "class JsonNullDSL; def to_json(*args) nil.to_json(*args) end end"
def remove_nil(val)
  case val
    when Array
      val.compact!
      val.each { |v| remove_nil(v) }
    when Hash
      val.delete_if { |k, v| k == nil || v == nil }
      val.values.each { |v| remove_nil(v) }
    when JsonObjectDSL
      val.compact!
    else
  end
end

############################# CloudFormation DSL

# main entry point
def template(&block)
  TemplateDSL.new(&block)
end

class TemplateDSL < JsonObjectDSL
  attr_reader :parameters, :aws_region, :aws_stack_name

  def initialize()
    @parameters, @aws_region, @aws_stack_name = cfn_parse_args
    super
  end

  def exec!()
    cfn_cmd(self)
  end

  def parameter(name, options)
    default(:Parameters, {})[name] = options
    @parameters[name] ||= options[:Default]
  end

  def mapping(name, options)
    # if options is a string and a valid file then the script will process the external file.
    if options.is_a?(String) and File.exists?(options)
      filename = options

      # Figure out what the file extension is and process accordingly.
      case File.extname(filename)
        when ".rb"
          raise("Can not handle ruby files yet.")
        when ".json"
          options = JSON.load(File.open(filename))['Mappings'][name]
        when ".yaml"
          options = YAML::load_file(filename)['Mappings'][name]
        else
          raise("Do not recognize extension of #{filename}.")
      end
      default(:Mappings, {})[name] = options

    elsif options.is_a?(Hash)
      default(:Mappings, {})[name] = options
    else
      raise("Options for mapping #{name} is neither a string or a hash.  Error!")
    end
  end

  def resource(name, options) default(:Resources, {})[name] = options end

  def output(name, options) default(:Outputs, {})[name] = options end
end

def base64(value) { :'Fn::Base64' => value } end

def find_in_map(map, key, value) { :'Fn::FindInMap' => [ map, key, value ] } end

def get_att(resource, attribute) { :'Fn::GetAtt' => [ resource, attribute ] } end

def get_azs(region = '') { :'Fn::GetAZs' => region } end

def join(delim, *list)
  case list.length
    when 0 then ''
    when 1 then list[0]
    else {:'Fn::Join' => [ delim, list ] }
  end
end

# Variant of join that matches the native CFN syntax.
def join_list(delim, list) { :'Fn::Join' => [ delim, list ] } end

def select(index, list) { :'Fn::Select' => [ index, list ] } end

def ref(name) { :Ref => name } end

# Read the specified file and return its value as a string literal
def file(filename) File.read(File.absolute_path(filename, File.dirname($PROGRAM_NAME))) end

# Interpolates a string like "NAME={{join('-', ref('Env'), ref('Service'))}}" and returns a
# CloudFormation "Fn::Join" operation using the specified delimiter.  Anything between {{
# and }} is interpreted as a Ruby expression and eval'd.  This is especially useful with
# Ruby "here" documents.
def join_interpolate(delim, string, overrides={}.freeze)
  list = []
  while string.length > 0
    head, match, tail = string.partition(/\{\{.*?\}\}/)
    list << head if head.length > 0
    if match.length > 0
      match_expr = match[2..-3]
      if overrides[match_expr]
        list << overrides[match_expr]
      else
        list << eval(match_expr)
      end
    end
    string = tail
  end

  # If 'delim' is specified, return a two-level set of joins: a top-level join() with the
  # specified delimiter and nested join()s on the empty string as necessary.
  if delim != ''
    # If delim=="\n", split "abc\ndef\nghi" into ["abc", "\n", "def", "\n", "ghi"] so the newline
    # characters are by themselves.  Then join() the values in each chunk between newlines.
    list = list.flat_map do |v|
      if v.is_a?(String)
        v.split(Regexp.new("(#{Regexp.escape(delim)})")).reject { |s| s == '' }
      else
        [ v ]
      end
    end.chunk { |v| v == delim }.map do |k, a|
      join('', *a) unless k
    end.compact
  end

  join(delim, *list)
end

# This class is used by erb templates so they can access the parameters passed
class Namespace
  attr_accessor :params
  def initialize(hash)
    @params = hash
  end
  def get_binding
    binding
  end
end

# Combines the provided ERB template with optional parameters
def erb_template(filename, params = {})
  renderer = ERB.new(file(filename), nil, '-')
  ERB.new(file(filename), nil, '-').result(Namespace.new(params).get_binding)
end
require 'cucumber/formatter/ordered_xml_markup'
require 'cucumber/formatter/duration'

class TextmateFormatter < Cucumber::Ast::Visitor

    include ERB::Util # for the #h method
    include Cucumber::Formatter::Duration
    include Cucumber::Formatter

    def initialize(step_mother, io, options)
      super(step_mother)
      @options = options
      @builder = create_builder(io)
      @feature_number = 0
      @scenario_number = 0
      @step_number = 0
      @header_red = nil
    end
    
    def create_builder(io)
      OrderedXmlMarkup.new(:target => io, :indent => 0)
    end
    
    def visit_features(features)
      @step_count = get_step_count(features)
      # <!DOCTYPE html PUBLIC "-//W3C//DTD XHTML 1.0 Strict//EN" "http://www.w3.org/TR/xhtml1/DTD/xhtml1-strict.dtd">
      @builder.declare!(
        :DOCTYPE,
        :html, 
        :PUBLIC, 
        '-//W3C//DTD XHTML 1.0 Strict//EN', 
        'http://www.w3.org/TR/xhtml1/DTD/xhtml1-strict.dtd'
      )
      @builder.html(:xmlns => 'http://www.w3.org/1999/xhtml') do
        @builder.head do
          @builder.meta(:content => 'text/html;charset=utf-8')
          @builder.title 'Cucumber'
          inline_css
          inline_js
        end
        @builder.body do
          @builder << "<!-- Step count #{@step_count}-->"
          @builder.div(:class => 'cucumber') do
            @builder.div(:id => 'cucumber-header') do
              @builder.div(:id => 'label') do
                @builder.h1('Cucumber Features')
              end
              @builder.div(:id => 'summary') do
                @builder.p('',:id => 'totals')
                @builder.p('',:id => 'duration')
              end
            end
            super
          end
          print_stats(features)
        end
      end
    end

    def visit_comment(comment)
      @builder.pre(:class => 'comment') do
        super
      end
    end

    def visit_comment_line(comment_line)
      @builder.text!(comment_line)
      @builder.br
    end

    def visit_feature(feature)
      @exceptions = []
      @builder.div(:class => 'feature') do
        super
      end
    end

    def visit_tags(tags)
      super
      @tag_spacer = nil
    end

    def visit_tag_name(tag_name)
      @builder.text!(@tag_spacer) if @tag_spacer
      @tag_spacer = ' '
      @builder.span("@#{tag_name}", :class => 'tag')
    end

    def visit_feature_name(name)
      lines = name.split(/\r?\n/)
      return if lines.empty?
      @builder.h2 do |h2|
        @builder.span(lines[0], :class => 'val')
      end
      @builder.p(:class => 'narrative') do
        lines[1..-1].each do |line|
          @builder.text!(line.strip)
          @builder.br
        end
      end
    end

    def visit_background(background)
      @builder.div(:class => 'background') do
        @in_background = true
        super
        @in_background = nil
      end
    end

    def visit_background_name(keyword, name, file_colon_line, source_indent)
      @listing_background = true
      @builder.h3 do |h3|
        @builder.span(keyword, :class => 'keyword')
        @builder.text!(' ')
        @builder.span(name, :class => 'val')
      end
    end

    def visit_feature_element(feature_element)
      @scenario_number+=1
      @scenario_red = false
      css_class = {
        Cucumber::Ast::Scenario        => 'scenario',
        Cucumber::Ast::ScenarioOutline => 'scenario outline'
      }[feature_element.class]
      @builder.div(:class => css_class) do
        super
      end
      @open_step_list = true
    end
    
    def visit_scenario_name(keyword, name, file_colon_line, source_indent)
      @listing_background = false
      @builder.h3(:id => "scenario_#{@scenario_number}") do
        @builder.span(keyword, :class => 'keyword')
        @builder.text!(' ')
        @builder.span(name, :class => 'val')
      end
    end

    def visit_outline_table(outline_table)
      @outline_row = 0
      @builder.table do
        super(outline_table)
      end
      @outline_row = nil
    end

    def visit_examples(examples)
      @builder.div(:class => 'examples') do
        super(examples)
      end
    end

    def visit_examples_name(keyword, name)
      @builder.h4 do
        @builder.span(keyword, :class => 'keyword')
        @builder.text!(' ')
        @builder.span(name, :class => 'val')
      end
    end

    def visit_steps(steps)
      @builder.ol do
        super
      end
    end

    def visit_step(step)
      @step_number += 1
      @step_id = step.dom_id
      super
      move_progress
    end

    def visit_step_result(keyword, step_match, multiline_arg, status, exception, source_indent, background)
      @step_match = step_match
      if exception
        return if @exceptions.index(exception)
        @exceptions << exception
      end
      return if status != :failed && @in_background ^ background
      @status = status
      
      set_scenario_color(status)
      
      @builder.li(:id => @step_id, :class => "step #{status}") do
        super(keyword, step_match, multiline_arg, status, exception, source_indent, background)
      end
      
    end

    def visit_step_name(keyword, step_match, status, source_indent, background)
      @step_matches ||= []
      background_in_scenario = background && !@listing_background
      @skip_step = @step_matches.index(step_match) || background_in_scenario
      @step_matches << step_match

      unless @skip_step
        build_step(keyword, step_match, status)
      end
    end

    def visit_exception(exception, status)
      build_exception_detail(exception)
    end
    
    def extra_failure_content(file_colon_line)
      @snippet_extractor ||= SnippetExtractor.new
      "<pre class=\"ruby\"><code>#{@snippet_extractor.snippet(file_colon_line)}</code></pre>"
    end

    def visit_multiline_arg(multiline_arg)
      return if @skip_step
      if Cucumber::Ast::Table === multiline_arg
        @builder.table do
          super
        end
      else
        super
      end
    end

    def visit_py_string(string)
      @builder.pre(:class => 'val') do |pre|
        @builder << string.gsub("\n", '&#x000A;')
      end
    end

    def visit_table_row(table_row)
      @row_id = table_row.dom_id
      @col_index = 0
      @builder.tr(:class => 'step') do
        super
      end
      if table_row.exception
        @builder.tr do
          @builder.td(:colspan => @col_index.to_s,:class => 'step failed') do
            build_exception_detail(table_row.exception)
          end
        end
      end
      if @outline_row > 0
        @step_number += 1
        move_progress
      end
      @outline_row += 1 if @outline_row
    end

    def visit_table_cell_value(value, status)
      @cell_type = @outline_row == 0 ? :th : :td
      attributes = {:id => "#{@row_id}_#{@col_index}", :class => 'step'}
      attributes[:class] += " #{status}" if status
      build_cell(@cell_type, value, attributes)
      set_scenario_color(status)
      @col_index += 1
    end
    
    def announce(announcement)
      @builder.pre(announcement, :class => 'announcement')
    end

    protected
    
    def build_exception_detail(exception)
      backtrace = Array.new
      @builder.div(:class => 'message') do
        @builder.pre(exception.message)
      end
      @builder.div(:class => 'backtrace') do
        @builder.pre do
          backtrace = exception.backtrace.size == 1 ? ["#{RAILS_ROOT}/#{@step_match.file_colon_line}"] + exception.backtrace : exception.backtrace
          @builder << backtrace_line(backtrace.join("\n"))
        end
      end
      extra = extra_failure_content(backtrace[0])
      @builder << extra unless extra == ""
    end
    
    def set_scenario_color(status)
      if status == :undefined
        @builder.script do
          @builder.text!("makeYellow('cucumber-header');") unless @header_red
          @builder.text!("makeYellow('scenario_#{@scenario_number}');") unless @scenario_red
        end 
      end
      if status == :failed
        @builder.script do
          @builder.text!("makeRed('cucumber-header');") unless @header_red
          @header_red = true
          @builder.text!("makeRed('scenario_#{@scenario_number}');") unless @scenario_red
          @scenario_red = true
        end
      end
    end
    
    def get_step_count(features)
      count = 0
      features = features.instance_variable_get("@features")
      features.each do |feature|
        #get background steps
        if feature.instance_variable_get("@background")
          background = feature.instance_variable_get("@background").instance_variable_get("@steps").instance_variable_get("@steps")
          count += background.size
        end
        #get scenarios
        feature.instance_variable_get("@feature_elements").each do |scenario|
          #get steps
          steps = scenario.instance_variable_get("@steps").instance_variable_get("@steps")
          count += steps.size
          
          #get example table
          examples = scenario.instance_variable_get("@examples_array")
          examples.each do |example|
            example_matrix = example.instance_variable_get("@outline_table").instance_variable_get("@cell_matrix")
            count += (example_matrix.size - 1)
          end
          
          #get multiline step tables
          steps.each do |step|
            multi_arg = step.instance_variable_get("@multiline_arg")
            next if multi_arg.nil?
            matrix = multi_arg.instance_variable_get("@cell_matrix")
            count += matrix.size - matrix.first.size
          end
        end
      end
      return count
    end
    
    def build_step(keyword, step_match, status)
      step_name = step_match.format_args(lambda{|param| %{<span class="param">#{param}</span>}})
      @builder.div do |div|
        @builder.span(keyword, :class => 'keyword')
        @builder.text!(' ')
        @builder.span(:class => 'step val') do |name|
          name << h(step_name).gsub(/&lt;span class=&quot;(.*?)&quot;&gt;/, '<span class="\1">').gsub(/&lt;\/span&gt;/, '</span>')
        end
      end
    end
    
    def build_cell(cell_type, value, attributes)
      @builder.__send__(cell_type, attributes) do
        @builder.div do
          @builder.span(value,:class => 'step param')
        end
      end
    end

    def inline_css
      @builder.style(:type => 'text/css') do
        @builder.text!(File.read(File.dirname(__FILE__) + '/cucumber-textmate.css'))
      end
    end
    
    def inline_js
      @builder.script(:type => 'text/javascript') do
        @builder.text!(inline_js_content)
      end
    end
    
    def inline_js_content
      <<-EOF
function moveProgressBar(percentDone) {
  document.getElementById("cucumber-header").style.width = percentDone +"%";
}
function makeRed(element_id) {
  document.getElementById(element_id).style.background = '#C40D0D';
  document.getElementById(element_id).style.color = '#FFFFFF';
}

function makeYellow(element_id) {
  document.getElementById(element_id).style.background = '#FAF834';
  document.getElementById(element_id).style.color = '#000000';
}
EOF
    end
    
    def move_progress
      @builder << " <script type=\"text/javascript\">moveProgressBar('#{percent_done}');</script>"
    end

    def percent_done
      result = 100.0
      if @step_count != 0
        result = ((@step_number).to_f / @step_count.to_f * 1000).to_i / 10.0
      end
      result
    end

    def format_exception(exception)
      (["#{exception.message}"] + exception.backtrace).join("\n")
    end
    
    def backtrace_line(line)
      line.gsub(/([^:]*\.(?:rb|feature)):(\d*)/) do
        "<a href=\"txmt://open?url=file://#{File.expand_path($1)}&line=#{$2}\">#{$1}:#{$2}</a> "
      end
    end
    
    def print_stats(features)
      @builder <<  "<script type=\"text/javascript\">document.getElementById('duration').innerHTML = \"Finished in <strong>#{format_duration(features.duration)} seconds</strong>\";</script>"
      @builder <<  "<script type=\"text/javascript\">document.getElementById('totals').innerHTML = \"#{print_stat_string(features)}\";</script>"
    end
    
    def print_stat_string(features)
      string = String.new

      string << dump_count(step_mother.scenarios.length, "scenario")
      string << print_status_counts{|status| step_mother.scenarios(status)}
      string << "<br />"
      string << dump_count(step_mother.steps.length, "step")
      string << print_status_counts{|status| step_mother.steps(status)}
    end
    
    def print_status_counts
      counts = [:failed, :skipped, :undefined, :pending, :passed].map do |status|
        elements = yield status
        elements.any? ? "#{elements.length} #{status.to_s}" : nil
      end.compact
      return " (#{counts.join(', ')})" if counts.any?
    end

    def dump_count(count, what, state=nil)
      [count, state, "#{what}#{count == 1 ? '' : 's'}"].compact.join(" ")
    end
    
end

class SnippetExtractor #:nodoc:
  class NullConverter; def convert(code, pre); code; end; end #:nodoc:
  begin; require 'syntax/convertors/html'; @@converter = Syntax::Convertors::HTML.for_syntax "ruby"; rescue LoadError => e; @@converter = NullConverter.new; end
  
  def snippet(error)
    raw_code, line = snippet_for(error)
    highlighted = @@converter.convert(raw_code, false)
    highlighted << "\n<span class=\"comment\"># gem install syntax to get syntax highlighting</span>" if @@converter.is_a?(NullConverter)
    post_process(highlighted, line)
  end
  
  def snippet_for(error_line)
    if error_line =~ /(.*):(\d+)/
      file = $1
      line = $2.to_i
      [lines_around(file, line), line]
    else
      ["# Couldn't get snippet for #{error_line}", 1]
    end
  end
  
  def lines_around(file, line)
    if File.file?(file)
      lines = File.open(file).read.split("\n")
      min = [0, line-3].max
      max = [line+1, lines.length-1].min
      selected_lines = []
      selected_lines.join("\n")
      lines[min..max].join("\n")
    else
      "# Couldn't get snippet for #{file}"
    end
  end
  
  def post_process(highlighted, offending_line)
    new_lines = []
    highlighted.split("\n").each_with_index do |line, i|
      new_line = "<span class=\"linenum\">#{offending_line+i-2}</span>#{line}"
      new_line = "<span class=\"offending\">#{new_line}</span>" if i == 2
      new_lines << new_line
    end
    new_lines.join("\n")
  end
  
end

require 'rblineprof'
require 'term/ansicolor'
require 'ltsv'
require 'pry'

module Rack
  class Lineprof

    autoload :Sample, 'rack/lineprof/sample'
    autoload :Source, 'rack/lineprof/source'

    CONTEXT  = 0
    NOMINAL  = 1
    WARNING  = 2
    CRITICAL = 3

    attr_reader :app, :options

    def initialize(app, options = {})
      @app, @options = app, options
    end

    def call(env)
      request = Rack::Request.new env
      matcher = request.params['lineprof'] || options[:profile]

      return @app.call env unless matcher

      response = nil
      raw_profile = lineprof(%r{#{matcher}}) { response = @app.call env }

      unless raw_profile.empty?
        profile = format_profile(raw_profile)
        output_profile(profile)
        write_log(profile)
      end

      response
    end

    def write_log(profile)
      return unless options[:log_path]
      profile.map do |source|
        source.samples.select{|v| v.calls != 0 }.each do |sample|
          ::File.write(
            options[:log_path],
            LTSV.dump(
              file: source.file_name,
              ms: sample.ms,
              calls: sample.calls,
              line: sample.line,
              code: sample.code,
              level: sample.level
            ) + "\n"
          )
        end
      end
    end

    def output_profile(profile)
      puts Term::ANSIColor.blue("\n[Rack::Lineprof] #{'=' * 63}") + "\n\n" +
           profile.map(&:format).compact.join + "\n\n"
    end

    def format_profile(raw_profile)
      raw_profile.map do |filename, samples|
        Source.new(filename, samples, options)
      end
    end
  end
end

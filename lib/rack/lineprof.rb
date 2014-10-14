require 'rblineprof'
require 'term/ansicolor'
require 'ltsv'
require 'benchmark'

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
      raw_profile = nil
      response_time = Benchmark.realtime do
        raw_profile = lineprof(%r{#{matcher}}) { response = @app.call env }
      end

      response_time = response_time * 1000.to_f

      request_id = SecureRandom.uuid

      unless raw_profile.empty?
        profile = format_profile(raw_profile)
        output_profile(profile)
        write_request_log(request_id, response_time, request, profile)
        write_log(request_id, response_time, profile)
      end

      response
    end

    def write_request_log(request_id, response_time, request, profile)
      return unless options[:request_log_path]
      ::File.open(options[:request_log_path], 'a') do |f|
        f.write(
          LTSV.dump(
            request_id: request_id,
            response_time: response_time,
            method: request.request_method,
            uri: request.fullpath,
            request_body: request.body.read,
            source: profile.map{|v| v.format(false) }.compact.join,
            time: Time.now.strftime('%Y-%m-%d %H:%M:%S')
          ) + "\n"
        )
      end
    end

    def write_log(request_id, response_time, profile)
      return unless options[:log_path]
      profile.map do |source|
        source.samples.select{|v| v.calls != 0 }.each do |sample|
          ::File.open(options[:log_path], 'a') do |f|
            f.write(
              LTSV.dump(
                request_id: request_id,
                response_time: response_time,
                file: source.file_name,
                ms: sample.ms,
                calls: sample.calls,
                line: sample.line,
                code: sample.code,
                level: sample.level,
                time: Time.now.strftime('%Y-%m-%d %H:%M:%S')
              ) + "\n"
            )
          end
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

require 'rblineprof'
require 'term/ansicolor'
require 'ltsv'
require 'benchmark'
require 'fluent-logger'

module Rack
  class Lineprof

    autoload :Sample, 'rack/lineprof/sample'
    autoload :Source, 'rack/lineprof/source'

    CONTEXT  = 0
    NOMINAL  = 1
    WARNING  = 2
    CRITICAL = 3

    LOGGER = Fluent::Logger::FluentLogger.new(nil, host: 'localhost', port: 24234)

    LINE = '%10.1fms %5i %10.1fms | % 3i  %s'
    EMPTY_LINE = '                                | % 3i  %s'

    attr_reader :app, :options

    def initialize(app, options = {})
      @app, @options = app, options
      @sources = {}
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

      pr = lineprof(/rack\/lineprof/) do
        if raw_profile.length != 0 && (!options[:request_log].nil? || !options[:request_log_path].nil?)
          request_id = SecureRandom.uuid
          raw_profile.each do |file, samples|
            next unless /#{matcher}/ =~ file
            # Write line profile log
            results = []
            if @sources[file].nil?
              @sources[file] = ::File.readlines(file)
            end
            @sources[file].each.with_index(1) do |code, line|
              wall, cpu, calls = samples[line]

              ms = wall / 1000.0
              avg = ms / calls

              if wall > 0
                results << LINE % [ms, calls, avg, line, code]
                if !options[:line_log].nil?
                  LOGGER.post(
                    'ruby_line_profile_logs',
                    request_id: request_id,
                    response_time: response_time,
                    file: file,
                    ms: ms,
                    calls: calls,
                    avg: avg,
                    line: line,
                    code: code,
                    time: Time.now.strftime('%Y-%m-%d %H:%M:%S')
                  )
                end

                if !options[:line_log_path].nil?
                  ::File.open(options[:line_log_path], 'a') do |f|
                    f.write(
                      LTSV.dump(
                        request_id: request_id,
                        response_time: response_time,
                        file: file,
                        ms: ms,
                        calls: calls,
                        avg: avg,
                        line: line,
                        code: code,
                        time: Time.now.strftime('%Y-%m-%d %H:%M:%S')
                      ) + "\n"
                    )
                  end
                end
              else
                results << EMPTY_LINE % [line, code]
              end
            end

            if !options[:request_log].nil?
              LOGGER.post(
                'ruby_request_profile_logs',
                request_id: request_id,
                response_time: response_time,
                method: request.request_method,
                uri: request.fullpath,
                request_body: request.body.read,
                source: results.join,
                time: Time.now.strftime('%Y-%m-%d %H:%M:%S')
              )
            end

            if !options[:request_log_path].nil?
              ::File.open(options[:request_log_path], 'a') do |f|
                f.write(
                  LTSV.dump(
                    request_id: request_id,
                    response_time: response_time,
                    method: request.request_method,
                    uri: request.fullpath,
                    request_body: request.body.read,
                    source: results.join,
                    time: Time.now.strftime('%Y-%m-%d %H:%M:%S')
                  ) + "\n"
                )
              end
            end
          end
        end
      end
      output_profile(format_profile(pr))

      response
    end

    def write_request_log(request_id, response_time, request, profile)
      unless options[:request_log].nil?
        LOGGER.post(
          'ruby_request_profile_logs',
          request_id: request_id,
          response_time: response_time,
          method: request.request_method,
          uri: request.fullpath,
          request_body: request.body.read,
          source: profile.map{|v| v.format(false) }.compact.join,
          time: Time.now.strftime('%Y-%m-%d %H:%M:%S')
        )
      end
      unless options[:request_log_path].nil?
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
    end

    def write_log(request_id, response_time, profile)
      unless options[:line_log].nil?
        profile.map do |source|
          source.samples.select{|v| v.calls != 0 }.each do |sample|
            LOGGER.post(
              'ruby_line_profile_logs',
              request_id: request_id,
              response_time: response_time,
              file: source.file_name,
              ms: sample.ms,
              calls: sample.calls,
              line: sample.line,
              code: sample.code,
              level: sample.level,
              time: Time.now.strftime('%Y-%m-%d %H:%M:%S')
            )
          end
        end
      end
      unless options[:log_path].nil?
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

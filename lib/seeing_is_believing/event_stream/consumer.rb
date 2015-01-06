require 'seeing_is_believing/event_stream/events'
require 'seeing_is_believing/error'
require 'thread'

class SeeingIsBelieving
  module EventStream
    class Consumer
      NoMoreInput        = Class.new SeeingIsBelievingError
      WtfWhoClosedMyShit = Class.new SeeingIsBelievingError
      UnknownEvent       = Class.new SeeingIsBelievingError

      def initialize(streams)
        self.finished_threads = []
        self.queue            = Thread::Queue.new
        self.event_stream     = streams.fetch :events
        stdout_stream         = streams.fetch :stdout
        stderr_stream         = streams.fetch :stderr

        self.stdout_thread = Thread.new do
          stdout_stream.each_line { |line| queue << Events::Stdout.new(line) }
          queue << :stdout_thread_finished
        end

        self.stderr_thread = Thread.new do
          stderr_stream.each_line { |line| queue << Events::Stderr.new(line) }
          queue << :stderr_thread_finished
        end

        self.event_thread = Thread.new do
          begin loop do
                   break unless line = event_stream.gets
                   event = event_for line
                   queue << event
                 end
          rescue IOError; queue << WtfWhoClosedMyShit.new("Our end of the pipe was closed!")
          rescue SeeingIsBelievingError; queue << $!
          ensure queue << :event_thread_finished
          end
        end
      end

      def call(n=1)
        return next_event if n == 1
        Array.new(n) { next_event }
      end

      def each
        return to_enum :each unless block_given?
        loop { yield call(1) }
      rescue NoMoreInput
      end

      private

      attr_accessor :queue, :event_stream, :finished_threads
      attr_accessor :event_thread, :stdout_thread, :stderr_thread

      def next_event
        raise NoMoreInput if @no_more_input

        case event = queue.shift
        when Symbol
          @no_more_input = true if finished_threads.push(event).size == 3
          next_event
        when SeeingIsBelievingError
          raise event
        else
          event
        end
      end

      def extract_token(line)
        event_name = line[/[^ ]+/]
        line.sub! /^\s*[^ ]+\s*/, ''
        event_name
      end

      # for a consideration of many different ways of doing this, see 5633064
      def extract_string(line)
        Marshal.load extract_token(line).unpack('m0').first
      end

      def tokenize(line)
        line.split(' ')
      end

      def event_for(original_line)
        line       = original_line.chomp
        event_name = extract_token(line).intern
        case event_name
        when :result
          line_number = extract_token(line).to_i
          type        = extract_token(line).intern
          inspected   = extract_string(line)
          Events::LineResult.new(type, line_number, inspected)
        when :maxed_result
          line_number = extract_token(line).to_i
          type        = extract_token(line).intern
          Events::UnrecordedResult.new(type, line_number)
        when :exception
          Events::Exception.new(-1, '', '', []).tap do |exception|
            loop do
              line = event_stream.gets.chomp
              case extract_token(line).intern
              when :line_number   then exception.line_number = extract_token(line).to_i
              when :class_name    then exception.class_name  = extract_string(line)
              when :message       then exception.message     = extract_string(line)
              when :backtrace     then exception.backtrace << extract_string(line)
              when :end           then break
              end
            end
          end
        when :max_line_captures
          token = extract_token(line)
          value = token =~ /infinity/i ? Float::INFINITY : token.to_i
          Events::MaxLineCaptures.new(value)
        when :exitstatus
          Events::Exitstatus.new(extract_token(line).to_i)
        when :num_lines
          Events::NumLines.new(extract_token(line).to_i)
        when :sib_version
          Events::SiBVersion.new(extract_string line)
        when :ruby_version
          Events::RubyVersion.new(extract_string line)
        when :filename
          Events::Filename.new(extract_string line)
        else
          raise UnknownEvent, original_line.inspect
        end
      end
    end
  end
end

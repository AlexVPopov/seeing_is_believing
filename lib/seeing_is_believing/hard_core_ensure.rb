class SeeingIsBelieving
  class HardCoreEnsure
    def self.call(options)
      new(options).call
    end

    def initialize(options)
      self.options = options
      validate_options
    end

    def call
      trap_sigint
      invoke_code
    ensure
      invoke_ensure
    end

    private

    attr_accessor :options, :ensure_invoked, :old_handler

    def trap_sigint
      self.old_handler = trap 'INT' do
        invoke_ensure
        Process.kill 'INT', $$
      end
      trap 'INT', old_handler if ignore_interrupt? old_handler
    end

    def invoke_code
      options[:code].call
    end

    def invoke_ensure
      return if ensure_invoked
      self.ensure_invoked = true
      trap 'INT', old_handler
      options[:ensure].call
    end

    def validate_options
      raise ArgumentError, "Must pass the :code key"   unless options.key? :code
      raise ArgumentError, "Must pass the :ensure key" unless options.key? :ensure
      unknown_keys = options.keys - [:code, :ensure]
      if options.size == 3
        raise ArgumentError, "Unknown key: #{unknown_keys.first.inspect}"
      elsif options.size > 3
        raise ArgumentError, "Unknown keys: #{unknown_keys.map(&:inspect).join(', ')}"
      end
    end

    def ignore_interrupt?(interrupt_handler)
      # any handler that ignores gets normalized to IGNORE
      interrupt_handler == 'IGNORE'
    end
  end
end

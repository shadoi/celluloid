module Celluloid
  # Manages a fixed-size pool of workers
  module Worker
    def self.included(klass)
      klass.send :include, Celluloid
      klass.send :extend,  ClassMethods
    end
    
    # Class methods added to classes which include Celluloid::Worker
    module ClassMethods
      # Create a new pool of workers. Accepts the following options:
      #
      # * size: how many workers to create. Default is worker per CPU core
      # * args: array of arguments to pass when creating a worker
      #
      def pool(options = {})
        Manager.new(self, options)
      end
    end
    
    # Delegates work (i.e. methods) and supervises workers
    class Manager
      include Celluloid
      trap_exit :crash_handler
      
      def initialize(worker_class, options = {})
        @size = options[:size]
        raise ArgumentError, "minimum pool size is 2" if @size && @size < 2
        
        @size ||= [Celluloid.cores, 2].max
        @args = options[:args] ? Array(options[:args]) : []
        
        @worker_class = worker_class
        @idle = @size.times.map { worker_class.new_link(*@args) }
      end
      
      # Execute the given method within a worker
      def execute(method, *args, &block)
        worker = provision_worker
        
        begin
          worker._send_ method, *args, &block
        ensure
          @idle << worker if worker.alive?
        end
      end
      
      # Provision a new worker
      def provision_worker
        while @idle.empty?
          # Using exclusive mode blocks incoming messages, so they don't pile
          # up as waiting Celluloid::Tasks
          response = exclusive { receive { |msg| msg.is_a? Response } }
          Thread.current[:actor].handle_message(response)
        end
        @idle.shift
      end

      # Spawn a new worker for every crashed one
      def crash_handler(actor, reason)
        return unless reason # don't restart workers that exit cleanly
        @idle << @worker_class.new_link(*@args)
      end
      
      def respond_to?(method)
        super || (@worker_class ? @worker_class.instance_methods.include?(method.to_sym) : false)
      end
      
      def method_missing(method, *args, &block)
        if respond_to?(method)
          execute method, *args, &block
        else
          super
        end
      end
    end
  end
end
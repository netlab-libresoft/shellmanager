# Your starting point for daemon specific classes. This directory is
# already included in your load path, so no need to specify it.

require 'shellinabox'
require 'singleton'
require 'json'

module ShellManager
  class Controller
    include Singleton

    def start
      if @started
        DaemonKit.logger.error "Error: Controller already started"
        return
      end

      init_amqp
      @procs = {}
      @started = true
    end

    def stop
      if not @started
        DaemonKit.logger.error "Error: Controller is not started"
        return
      end

      shutdown_amqp
      @procs.values.each { |handler|  handler.stop }
      @started = false
    end

    private
    def init_amqp
      @chan = AMQP::Channel.new
      init_start_queue
      init_stop_queue
    end

    def shutdown_amqp
      shutdown_start_amqp
      shutdown_stop_amqp
      @chan.close
    end

    def init_start_queue
      #Start queue is a work queue used for distributing tasks among workers
      queue_name = "#{DAEMON_CONF[:root_service]}.start"
      DaemonKit.logger.debug "Creating queue #{queue_name}"
      @start_queue = @chan.queue(queue_name, :durable => true)

      @start_queue.subscribe do |metadata, payload|
        DaemonKit.logger.debug "[requests] start shellinabox #{payload}."
        begin
          req = JSON.parse(payload)
          start_process(req)
          #Todo: Send success notification
        rescue Exception => e
          DaemonKit.logger.error e.message
          DaemonKit.logger.error e.backtrace
          #Todo: Send error notification
        end
      end
    end

    def shutdown_start_amqp
      @start_queue.delete
    end

    def init_stop_queue
      #Stop queue is a publish/subscriber queue
      name = "#{DAEMON_CONF[:root_service]}.stop"
      @stop_exchange = @chan.fanout(name)
      @stop_queue = @chan.queue("", :exclusive => true, :auto_delete => true).bind(@stop_exchange)
      @stop_queue.subscribe do |metadata, payload|
        DaemonKit.logger.debug "[requests] stop shellinabox #{payload}."
        begin
          req = JSON.parse(payload)
          stop_process(req)
        rescue Exception => e
          DaemonKit.logger.error e.message
          DaemonKit.logger.error e.backtrace
        end
      end
    end

    def shutdown_stop_amqp
      @stop_queue.delete
      @stop_exchange.delete
    end

    def start_process(req)
      raise "Protocol error" if not req["id"]

      if @procs[req["id"]]
        handler = @procs.delete(req["id"])
        handler.on_finish do |pid|
          DaemonKit.logger.debug "Ignored process #{pid}"
        end
        handler.stop
      end

      handler = Shellinabox::Handler.new
      handler.on_finish do
        @procs.delete(req["id"])
        send_stop_msg(req["id"])
      end

      raise "Can't start shellinabox" if not handler.start(req)
      @procs[req["id"]] = handler
    end

    def stop_process(req)
      return if not req["id"]

      return if not @procs[req["id"]]

      @procs[req["id"]].stop
    end

    def send_stop_msg(id)
      DaemonKit.logger.debug "TODO: Send stop message #{id}"
    end
  end
end

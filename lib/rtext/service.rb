require 'socket'
require 'rtext/completer'
require 'rtext/context_builder'
require 'rtext/message_helper'
require 'rtext/link_detector'

module RText

class Service
  include RText::MessageHelper

  PortRangeStart = 9001
  PortRangeEnd   = 9100

  FlushInterval  = 1

  # Creates an RText backend service. Options:
  #
  #  :timeout
  #    idle time in seconds after which the service will terminate itelf
  #
  #  :logger
  #    a logger object on which the service will write its logging output
  #
  #  :on_startup:
  #    a Proc which is called right after the service has started up
  #    can be used to output version information
  #
  def initialize(service_provider, options={})
    @service_provider = service_provider
    @timeout = options[:timeout] || 60
    @logger = options[:logger]
    @on_startup = options[:on_startup]
  end

  def run
    server = create_server 
    puts "RText service, listening on port #{server.addr[1]}"
    @on_startup.call if @on_startup
    $stdout.flush

    last_access_time = Time.now
    last_flush_time = Time.now
    @stop_requested = false
    sockets = []
    request_data = {}
    while !@stop_requested
      begin
        sock = server.accept_nonblock
        sock.sync = true
        sockets << sock
        @logger.info "accepted connection" if @logger
      rescue Errno::EAGAIN, Errno::ECONNABORTED, Errno::EPROTO, Errno::EINTR, Errno::EWOULDBLOCK
      rescue Exception => e
        @logger.warn "unexpected exception during socket accept: #{e.class}"
      end
      sockets.dup.each do |sock|
        data = nil
        begin
          data = sock.read_nonblock(100000)
        rescue Errno::EWOULDBLOCK
        rescue IOError, EOFError, Errno::ECONNRESET, Errno::ECONNABORTED
          sock.close
          request_data[sock] = nil
          sockets.delete(sock)
        rescue Exception => e
          # catch Exception to make sure we don't crash due to unexpected exceptions
          @logger.warn "unexpected exception during socket read: #{e.class}"
          sock.close
          request_data[sock] = nil
          sockets.delete(sock)
        end
        if data
          last_access_time = Time.now
          request_data[sock] ||= ""
          request_data[sock].concat(data)
          while obj = extract_message(request_data[sock])
            message_received(sock, obj)
          end
        end
      end
      IO.select([server] + sockets, [], [], 1)
      if Time.now > last_access_time + @timeout
        @logger.info("RText service, stopping now (timeout)") if @logger
        break 
      end
      if Time.now > last_flush_time + FlushInterval
        $stdout.flush
        last_flush_time = Time.now
      end
    end
  end

  def message_received(sock, obj)
    if check_request(obj) 
      @logger.debug("request: "+obj.inspect) if @logger
      response = { "type" => "response", "invocation_id" => obj["invocation_id"] }
      case obj["command"]
      when "load_model"
        load_model(sock, obj, response)
      when "content_complete"
        content_complete(sock, obj, response)
      when "link_targets" 
        link_targets(sock, obj, response)
      when "find_elements"
        find_elements(sock, obj, response)
      when "stop"
        @logger.info("RText service, stopping now (stop requested)") if @logger
        @stop_requested = true
      else
        @logger.warn("unknown command #{obj["command"]}") if @logger
        response["type"] = "unknown_command_error"
        response["command"] = obj["command"] 
      end
      @logger.debug("response: "+response.inspect) if response && @logger
      send_response(sock, response)
    end
  end

  private

  def check_request(obj)
    if obj["type"] != "request" 
      @logger.warn("received message is not a request") if @logger
      false
    elsif !obj["invocation_id"].is_a?(Integer)
      @logger.warn("invalid invocation id #{obj["invocation_id"]}") if @logger
      false
    else
      true
    end
  end

  def load_model(sock, request, response)
    problems = @service_provider.get_problems(
      :on_progress => lambda do |frag, work_done, work_overall|
        work_overall = 1 if work_overall < 1
        work_done = work_overall if work_done > work_overall
        work_done = 0 if work_done < 0
        send_response(sock, {
          "type" => "progress",
          "invocation_id" => request["invocation_id"],
          "percentage" => work_done*100/work_overall
        })
      end)
    total = 0
    response["problems"] = problems.collect do |fp|
      { "file" => fp.file,
        "problems" => fp.problems.collect do |p| 
            total += 1
            { "severity" => "error", "line" => p.line, "message" => p.message }
          end }
    end
    response["total_problems"] = total
  end

  def content_complete(sock, request, response)
    # column numbers start at 1
    linepos = request["column"]-1 
    lines = request["context"]
    lang = @service_provider.language
    response["options"] = []
    return unless lang
    context = ContextBuilder.build_context(lang, lines, linepos)
    @logger.debug("context element: #{lang.identifier_provider.call(context.element, nil, nil, nil)}") \
      if context && context.element && @logger
    completer = RText::Completer.new(lang) 
    options = completer.complete(context, lambda {|ref| 
        @service_provider.get_reference_completion_options(ref, context).collect {|o|
          Completer::CompletionOption.new(o.identifier, "<#{o.type}>")}
      })
    response["options"] = options.collect do |o|
      { "insert" => o.text, "display" => "#{o.text} #{o.extra}" }
    end
  end

  def link_targets(sock, request, response)
    # column numbers start at 1
    linepos = request["column"]
    lines = request["context"]
    lang = @service_provider.language
    response["targets"] = []
    return unless lang
    link_descriptor = RText::LinkDetector.new(lang).detect(lines, linepos)
    if link_descriptor
      response["begin_column"] = link_descriptor.scol
      response["end_column"] = link_descriptor.ecol
      targets = []
      if link_descriptor.backward 
        @service_provider.get_referencing_elements(
            link_descriptor.value, link_descriptor.element, link_descriptor.feature, link_descriptor.index).each do |t|
          targets << { "file" => t.file, "line" => t.line, "display" => t.display_name }
        end
      else
        @service_provider.get_reference_targets(
            link_descriptor.value, link_descriptor.element, link_descriptor.feature, link_descriptor.index).each do |t|
          targets << { "file" => t.file, "line" => t.line, "display" => t.display_name }
        end
      end
      response["targets"] = targets
    end
  end

  def find_elements(sock, request, response)
    pattern = request["search_pattern"] 
    total = 0
    response["elements"] = @service_provider.get_open_element_choices(pattern).collect do |c|
      total += 1
      { "display" => c.display_name, "file" => c.file, "line" => c.line }
    end
    response["total_elements"] = total
  end

  def send_response(sock, response)
    if response
      begin
        sock.write(serialize_message(response))
        sock.flush
      # if there is an exception, the next read should shutdown the connection properly
      rescue IOError, EOFError, Errno::ECONNRESET, Errno::ECONNABORTED
      rescue Exception => e
        # catch Exception to make sure we don't crash due to unexpected exceptions
        @logger.warn "unexpected exception during socket write: #{e.class}"
      end
    end
  end

  def create_server
    port = PortRangeStart
    serv = nil
    begin
      serv = TCPServer.new("127.0.0.1", port)
    rescue Errno::EADDRINUSE, Errno::EAFNOSUPPORT, Errno::EACCES
      port += 1
      retry if port <= PortRangeEnd
      raise
    end
    serv
  end

end

end


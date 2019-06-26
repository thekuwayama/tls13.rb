# encoding: ascii-8bit
# frozen_string_literal: true

require_relative 'helper'

port = ARGV[0] || 4433

tcpserver = TCPServer.open(port)
settings = {
  crt_file: __dir__ + '/../tmp/server.crt',
  key_file: __dir__ + '/../tmp/server.key',
  alpn: ['http/1.1']
}

# rubocop: disable Metrics/BlockLength
loop do
  socket = tcpserver.accept
  Thread.start(socket) do |s|
    Timeout.timeout(2) do
      server = TTTLS13::Server.new(s, settings)
      server.accept

      parser = HTTP::Parser.new
      parser.on_message_complete = proc do
        if !parser.http_method.nil?
          @logger.info 'Receive Request'
          server.write(simple_http_response('TEST'))
        else
          @logger.warn 'Not Request'
        end
      end

      begin
        parser << server.read unless server.eof?
      rescue HTTP::Parser::Error
        @logger.warn 'Parser Error'
      end
      server.close
    end
  rescue Timeout::Error
    @logger.warn 'Timeout'
  ensure
    s.close
  end
end
# rubocop: enable Metrics/BlockLength

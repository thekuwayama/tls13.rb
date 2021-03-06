# encoding: ascii-8bit
# frozen_string_literal: true

require_relative 'helper'

hostname, port = (ARGV[0] || 'localhost:4433').split(':')
ca_file = __dir__ + '/../tmp/ca.crt'
req = simple_http_request(hostname)

socket = TCPSocket.new(hostname, port)
settings = {
  ca_file: File.exist?(ca_file) ? ca_file : nil,
  key_share_groups: [], # empty KeyShareClientHello.client_shares
  alpn: ['http/1.1']
}
client = TTTLS13::Client.new(socket, hostname, **settings)
client.connect
client.write(req)
print recv_http_response(client)
client.close unless client.eof?
socket.close

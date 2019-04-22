# encoding: ascii-8bit
# frozen_string_literal: true

require_relative 'helper'

hostname, port = (ARGV[0] || 'localhost:4433').split(':')

settings_2nd = {
  ca_file: __dir__ + '/../tmp/ca.crt'
}
process_new_session_ticket = proc do |nst, rms, cs|
  settings_2nd[:ticket] = nst.ticket
  settings_2nd[:resumption_master_secret] = rms
  settings_2nd[:psk_cipher_suite] = cs
  settings_2nd[:ticket_nonce] = nst.ticket_nonce
  settings_2nd[:ticket_age_add] = nst.ticket_age_add
  settings_2nd[:ticket_timestamp] = nst.timestamp
end
settings_1st = {
  ca_file: __dir__ + '/../tmp/ca.crt',
  process_new_session_ticket: process_new_session_ticket
}

accepted_early_data = false

[
  # Initial Handshake:
  settings_1st,
  # Subsequent Handshake:
  settings_2nd
].each_with_index do |settings, i|
  socket = TCPSocket.new(hostname, port)
  client = TLS13::Client.new(socket, hostname, settings)
  http_get = <<~BIN
    GET / HTTP/1.1\r
    Host: #{hostname}\r
    User-Agent: https_client\r
    Accept: */*\r
    \r
  BIN

  # send message using early data; 0-RTT
  client.early_data(http_get) if i == 1 && settings.include?(:ticket)
  client.connect
  # send message after Simple 1-RTT Handshake
  client.write(http_get) if i.zero? || !client.accepted_early_data?

  # status line, header
  buffer = ''
  buffer += client.read until buffer.include?("\r\n\r\n")
  print header = buffer.split("\r\n\r\n").first
  # header; Content-Length
  cl_line = header.split("\r\n").find { |s| s.match(/Content-Length:/i) }

  # body
  unless cl_line.nil?
    cl = cl_line.split(':').last.to_i
    print buffer = buffer.split("\r\n\r\n")[1..].join
    while buffer.length < cl
      print s = client.read
      buffer += s
    end
  end

  client.close
  accepted_early_data = client.accepted_early_data?
end

puts "\n" + '-' * 10
puts "early data of 2nd handshake: #{accepted_early_data}"

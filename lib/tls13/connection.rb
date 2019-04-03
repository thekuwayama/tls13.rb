# encoding: ascii-8bit
# frozen_string_literal: true

module TLS13
  CH1  = 0
  HRR  = 1
  CH   = 2
  SH   = 3
  EE   = 4
  CR   = 5
  CT   = 6
  CV   = 7
  SF   = 8
  EOED = 9
  CCT  = 10
  CCV  = 11
  CF   = 12

  # rubocop: disable Metrics/ClassLength
  class Connection
    # @param socket [Socket]
    def initialize(socket)
      @socket = socket
      @endpoint = nil # Symbol or String, :client or :server
      @key_schedule = nil # TLS13::KeySchedule
      @priv_keys = {} # Hash of NamedGroup => OpenSSL::PKey::$Object
      @read_cipher = Cryptograph::Passer.new
      @read_seq_num = nil # TLS13::SequenceNumber
      @write_cipher = Cryptograph::Passer.new
      @write_seq_num = nil # TLS13::SequenceNumber
      @transcript = {} # Hash of constant => TLS13::Message::$Object
      @message_queue = [] # Array of TLS13::Message::$Object
      @cipher_suite = nil # TLS13::CipherSuite
      @notyet_application_secret = true
      @state = 0 # ClientState or ServerState
    end

    # @raise [TLS13::Error::TLSError]
    #
    # @return [String]
    def read
      # secure channel has not established yet
      raise Error::ConfigError unless @endpoint == :client &&
                                      @state == ClientState::CONNECTED

      message = nil
      # At any time after the server has received the client Finished
      # message, it MAY send a NewSessionTicket message.
      loop do
        message = recv_message
        break unless message.is_a?(Message::NewSessionTicket)

        precess_new_session_ticket
      end
      raise message.to_error if message.is_a?(Message::Alert)

      message.fragment
    end

    # @param binary [String]
    def write(binary)
      # secure channel has not established yet
      raise Error::ConfigError unless @endpoint == :client &&
                                      @state == ClientState::CONNECTED

      ap = Message::ApplicationData.new(binary)
      send_application_data(ap)
    end

    private

    # @param type [Message::ContentType]
    # @param messages [Array of TLS13::Message::$Object] handshake messages
    def send_handshakes(type, messages)
      if @write_seq_num.nil? &&
         type == Message::ContentType::APPLICATION_DATA
        @write_seq_num = SequenceNumber.new
        @write_cipher \
        = gen_aead_with_handshake_traffic_secret(@write_seq_num, @endpoint)
      end
      record = Message::Record.new(type: type, messages: messages,
                                   cipher: @write_cipher)
      send_record(record)
      return if messages.none? { |m| m.is_a?(Message::Finished) }

      @write_seq_num = SequenceNumber.new
      @write_cipher \
      = gen_aead_with_application_traffic_secret(@write_seq_num, @endpoint)
    end

    def send_ccs
      ccs_record = Message::Record.new(
        type: Message::ContentType::CCS,
        legacy_record_version: Message::ProtocolVersion::TLS_1_2,
        messages: [Message::ChangeCipherSpec.new],
        cipher: Cryptograph::Passer.new
      )
      send_record(ccs_record)
    end

    # @param message [TLS13::Message::ApplicationData]
    def send_application_data(message)
      ap_record = Message::Record.new(
        type: Message::ContentType::APPLICATION_DATA,
        legacy_record_version: Message::ProtocolVersion::TLS_1_2,
        messages: [message],
        cipher: @write_cipher
      )
      send_record(ap_record)
    end

    # @param symbol [Symbol] key of ALERT_DESCRIPTION
    def send_alert(symbol)
      message = Message::Alert.new(
        description: Message::ALERT_DESCRIPTION[symbol]
      )
      alert_record = Message::Record.new(
        type: Message::ContentType::ALERT,
        legacy_record_version: Message::ProtocolVersion::TLS_1_2,
        messages: [message],
        cipher: @write_cipher
      )
      send_record(alert_record)
    end

    # @param record [TLS13::Message::Record]
    def send_record(record)
      @socket.write(record.serialize)
      @write_seq_num&.succ
    end

    # @return [TLS13::Message::$Object]
    # rubocop: disable Metrics/CyclomaticComplexity
    def recv_message
      return @message_queue.shift unless @message_queue.empty?

      loop do
        messages = []
        record = recv_record
        case record.type
        when Message::ContentType::HANDSHAKE
          messages = record.messages
        when Message::ContentType::APPLICATION_DATA
          messages = record.messages
        when Message::ContentType::CCS
          terminate(:unexpected_message) unless ccs_receivable?
          next
        when Message::ContentType::ALERT
          messages = record.messages
        else
          terminate(:unexpected_message)
        end
        @message_queue += messages[1..]
        return messages.first
      end
    end
    # rubocop: enable Metrics/CyclomaticComplexity

    # @return [TLS13::Message::Record]
    # rubocop: disable Metrics/CyclomaticComplexity
    # rubocop: disable Metrics/PerceivedComplexity
    def recv_record
      buffer = @socket.read(5)
      record_len = Convert.bin2i(buffer.slice(3, 2))
      buffer += @socket.read(record_len)
      if @read_seq_num.nil? &&
         buffer[0] == Message::ContentType::APPLICATION_DATA
        @read_seq_num = SequenceNumber.new
        sender = (@endpoint == :client ? :server : :client)
        @read_cipher \
        = gen_aead_with_handshake_traffic_secret(@read_seq_num, sender)
      elsif @transcript.key?(SF) && @notyet_application_secret
        @read_seq_num = SequenceNumber.new
        sender = (@endpoint == :client ? :server : :client)
        @read_cipher \
        = gen_aead_with_application_traffic_secret(@read_seq_num, sender)
        @notyet_application_secret = false
      end

      record = Message::Record.deserialize(buffer, @read_cipher)
      # Received a protected ccs, peer MUST abort the handshake.
      if record.type == Message::ContentType::APPLICATION_DATA &&
         record.messages.first.is_a?(Message::ChangeCipherSpec)
        terminate(:unexpected_message)
      end
      @read_seq_num&.succ
      record
    end
    # rubocop: enable Metrics/CyclomaticComplexity
    # rubocop: enable Metrics/PerceivedComplexity

    # @param range [Range]
    #
    # @return [String]
    def transcript_hash(range)
      # TODO: HRR
      messages = range.to_a.map do |m|
        @transcript.key?(m) ? @transcript[m].serialize : ''
      end.join
      digest = CipherSuite.digest(@cipher_suite)
      OpenSSL::Digest.digest(digest, messages)
    end

    # @param certificate_pem [String]
    # @param signature_scheme [TLS13::Message::SignatureScheme]
    # @param signature [String]
    # @param context [String]
    # @param message_range [Range]
    #
    # @raise [RuntimeError]
    #
    # @return [Boolean]
    def do_verify_certificate_verify(certificate_pem:, signature_scheme:,
                                     signature:, context:, message_range:)
      hash = transcript_hash(message_range)
      case signature_scheme
      when Message::SignatureScheme::RSA_PSS_RSAE_SHA256
        content = "\x20" * 64 + context + "\x00" + hash
        public_key = OpenSSL::X509::Certificate.new(certificate_pem).public_key
        public_key.verify_pss('SHA256', signature, content, salt_length: :auto,
                                                            mgf1_hash: 'SHA256')
      when Message::SignatureScheme::RSA_PSS_RSAE_SHA384
        content = "\x20" * 64 + context + "\x00" + hash
        public_key = OpenSSL::X509::Certificate.new(certificate_pem).public_key
        public_key.verify_pss('SHA384', signature, content, salt_length: :auto,
                                                            mgf1_hash: 'SHA384')
      else # TODO: other SignatureScheme
        terminate(:internal_error)
      end
    end

    # @param digest [String] name of digest algorithm
    # @param finished_key [String]
    # @param message_range [Range]
    #
    # @return [String]
    def do_sign_finished(digest:, finished_key:, message_range:)
      hash = transcript_hash(message_range)
      OpenSSL::HMAC.digest(digest, finished_key, hash)
    end

    # @param digest [String] name of digest algorithm
    # @param finished_key [String]
    # @param message_range [Range]
    # @param signature [String]
    #
    # @return [Boolean]
    def do_verify_finished(digest:, finished_key:, message_range:, signature:)
      do_sign_finished(digest: digest,
                       finished_key: finished_key,
                       message_range: message_range) == signature
    end

    # @param key_exchange [String]
    # @param priv_key [OpenSSL::PKey::$Object]
    # @param group [TLS13::Message::ExtensionType::NamedGroup]
    #
    # @return [String]
    def gen_shared_secret(key_exchange, priv_key, group)
      case group
      when Message::Extension::NamedGroup::SECP256R1
        pub_key = OpenSSL::PKey::EC::Point.new(
          OpenSSL::PKey::EC::Group.new('prime256v1'),
          OpenSSL::BN.new(key_exchange, 2)
        )
        priv_key.dh_compute_key(pub_key)
      else # TODO: other NamedGroup
        terminate(:internal_error)
      end
    end

    # @param seq_num [TLS13::SequenceNumber]
    # @param sender [Symbol, :client or :server]
    #
    # @return [TLS13::Cryptograph::Aead]
    def gen_aead_with_handshake_traffic_secret(seq_num, sender)
      ch_sh = transcript_hash(CH..SH)
      write_key = @key_schedule.send("#{sender}_handshake_write_key", ch_sh)
      write_iv = @key_schedule.send("#{sender}_handshake_write_iv", ch_sh)
      Cryptograph::Aead.new(
        cipher_suite: @cipher_suite,
        write_key: write_key,
        write_iv: write_iv,
        sequence_number: seq_num
      )
    end

    # @param seq_num [TLS13::SequenceNumber]
    # @param sender [Symbol, :client or :server]
    #
    # @return [TLS13::Cryptograph::Aead]
    def gen_aead_with_application_traffic_secret(seq_num, sender)
      ch_sf = transcript_hash(CH..SF)
      write_key = @key_schedule.send("#{sender}_application_write_key", ch_sf)
      write_iv = @key_schedule.send("#{sender}_application_write_iv", ch_sf)
      Cryptograph::Aead.new(
        cipher_suite: @cipher_suite,
        write_key: write_key,
        write_iv: write_iv,
        sequence_number: seq_num
      )
    end

    # @return [Boolean]
    #
    # Received ccs before the first ClientHello message or after the peer's
    # Finished message, peer MUST abort.
    def ccs_receivable?
      return false unless @transcript.key?(CH)
      return false if @endpoint == :client && @transcript.key?(SF)
      return false if @endpoint == :server && @transcript.key?(CF)

      true
    end

    # @param symbol [Symbol] key of ALERT_DESCRIPTION
    #
    # @raise [TLS13::Error::TLSError]
    def terminate(symbol)
      send_alert(symbol)
      raise Error::TLSError, symbol
    end

    # @raise [TLS13::Error::TLSError]
    def precess_new_session_ticket
      terminate(:unexpected_message) if @endpoint == :server
      # TODO: @endpoint == :client
    end
  end
  # rubocop: enable Metrics/ClassLength
end

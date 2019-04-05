# encoding: ascii-8bit
# frozen_string_literal: true

module TLS13
  module ClientState
    # initial value is 0
    START         = 1
    WAIT_SH       = 2
    WAIT_EE       = 3
    WAIT_CERT_CR  = 4
    WAIT_CERT     = 5
    WAIT_CV       = 6
    WAIT_FINISHED = 7
    CONNECTED     = 8
  end

  # rubocop: disable Metrics/ClassLength
  class Client < Connection
    attr_accessor :hostname

    def initialize(socket)
      super(socket)
      @endpoint = :client
      @hostname = ''
    end

    # rubocop: disable Metrics/AbcSize
    # rubocop: disable Metrics/BlockLength
    # rubocop: disable Metrics/CyclomaticComplexity
    # rubocop: disable Metrics/MethodLength
    # rubocop: disable Metrics/PerceivedComplexity
    def connect
      @state = ClientState::START
      loop do
        case @state
        when ClientState::START
          send_client_hello
          @state = ClientState::WAIT_SH
        when ClientState::WAIT_SH
          sh = recv_server_hello # TODO: Recv HelloRetryRequest
          # only TLS 1.3
          terminate(:protocol_version) unless negotiated_tls_1_3?
          terminate(:illegal_parameter) unless echoed_legacy_session_id?
          terminate(:illegal_parameter) unless offerd_cipher_suite?
          @cipher_suite = sh.cipher_suite
          terminate(:illegal_parameter) unless valid_compression_method?
          kse = sh.extensions[Message::ExtensionType::KEY_SHARE]
                  .key_share_entry.first
          key_exchange = kse.key_exchange
          group = kse.group
          priv_key = @priv_keys[group]
          shared_key = gen_shared_secret(key_exchange, priv_key, group)
          @key_schedule = KeySchedule.new(shared_secret: shared_key,
                                          cipher_suite: @cipher_suite)
          @state = ClientState::WAIT_EE
        when ClientState::WAIT_EE
          recv_encrypted_extensions
          # TODO: get server parameters
          # TODO: Using PSK
          @state = ClientState::WAIT_CERT_CR
        when ClientState::WAIT_CERT_CR
          message = recv_message
          if message.msg_type == Message::HandshakeType::CERTIFICATE
            @transcript[CT] = message
            @state = ClientState::WAIT_CV
          elsif message.msg_type == Message::HandshakeType::CERTIFICATE_REQUEST
            @transcript[CR] = message
            @state = ClientState::WAIT_CERT
          else
            terminate(:unexpected_message)
          end
        when ClientState::WAIT_CERT
          recv_certificate
          @state = ClientState::WAIT_CV
        when ClientState::WAIT_CV
          recv_certificate_verify
          terminate(:decrypt_error) unless verify_certificate_verify
          @state = ClientState::WAIT_FINISHED
        when ClientState::WAIT_FINISHED
          recv_finished
          terminate(:decrypt_error) unless verify_finished
          send_ccs # compatibility mode
          # TODO: Send EndOfEarlyData
          # TODO: Send Certificate [+ CertificateVerify]
          send_finished
          @state = ClientState::CONNECTED
        when ClientState::CONNECTED
          break
        end
      end
    end
    # rubocop: enable Metrics/AbcSize
    # rubocop: enable Metrics/BlockLength
    # rubocop: enable Metrics/CyclomaticComplexity
    # rubocop: enable Metrics/MethodLength
    # rubocop: enable Metrics/PerceivedComplexity

    private

    DOWNGRADE_PROTECTION_TLS_1_2 = "\x44\x4F\x57\x4E\x47\x52\x44\x01"
    DOWNGRADE_PROTECTION_TLS_1_1 = "\x44\x4F\x57\x4E\x47\x52\x44\x00"

    # @return [TLS13::Message::Extensions]
    def gen_extensions
      exs = []
      # supported_versions: only TLS 1.3
      exs << Message::Extension::SupportedVersions.new(
        msg_type: Message::HandshakeType::CLIENT_HELLO
      )
      # signature_algorithms
      exs << Message::Extension::SignatureAlgorithms.new(
        [Message::SignatureScheme::RSA_PSS_RSAE_SHA256,
         Message::SignatureScheme::RSA_PSS_RSAE_SHA384]
      )
      # supported_groups: only P-256
      exs << Message::Extension::SupportedGroups.new
      # key_share: only P-256
      ec = OpenSSL::PKey::EC.new('prime256v1')
      ec.generate_key!
      @priv_keys[Message::Extension::NamedGroup::SECP256R1] = ec
      exs << Message::Extension::KeyShare.new(
        msg_type: Message::HandshakeType::CLIENT_HELLO,
        key_share_entry: [
          Message::Extension::KeyShareEntry.new(
            group: Message::Extension::NamedGroup::SECP256R1,
            key_exchange: ec.public_key.to_octet_string(:uncompressed)
          )
        ]
      )
      # server_name
      exs << Message::Extension::ServerName.new(@hostname) \
        unless @hostname.nil? || @hostname.empty?

      Message::Extensions.new(exs)
    end

    # @return [TLS13::Message::ClientHello]
    def send_client_hello
      exs = gen_extensions
      ch = Message::ClientHello.new(
        cipher_suites: CipherSuites.new,
        extensions: exs
      )
      send_handshakes(Message::ContentType::HANDSHAKE, [ch])
      @transcript[CH] = ch
    end

    # @raise [TLS13::Error::TLSError]
    #
    # @return [TLS13::Message::ServerHello]
    def recv_server_hello
      sh = recv_message
      terminate(:unexpected_message) unless sh.is_a?(Message::ServerHello)

      @transcript[SH] = sh
    end

    # @raise [TLS13::Error::TLSError]
    #
    # @return [TLS13::Message::EncryptedExtensions]
    def recv_encrypted_extensions
      ee = recv_message
      terminate(:unexpected_message) \
        unless ee.is_a?(Message::EncryptedExtensions)
      terminate(:illegal_parameter) if ee.any_forbidden_extensions?

      @transcript[EE] = ee
    end

    # @raise [TLS13::Error::TLSError]
    #
    # @return [TLS13::Message::Certificate]
    def recv_certificate
      ct = recv_message
      terminate(:unexpected_message) unless ct.is_a?(Message::Certificate)

      @transcript[CT] = ct
    end

    # @raise [TLS13::Error::TLSError]
    #
    # @return [TLS13::Message::CertificateVerify]
    def recv_certificate_verify
      cv = recv_message
      terminate(:unexpected_message) unless cv.is_a?(Message::CertificateVerify)

      @transcript[CV] = cv
    end

    # @raise [TLS13::Error::TLSError]
    #
    # @return [TLS13::Message::Finished]
    def recv_finished
      sf = recv_message
      terminate(:unexpected_message) unless sf.is_a?(Message::Finished)

      @transcript[SF] = sf
    end

    # @return [TLS13::Message::Finished]
    def send_finished
      cf = Message::Finished.new(sign_finished)
      send_handshakes(Message::ContentType::APPLICATION_DATA, [cf])
      @transcript[CF] = cf
    end

    # @return [Boolean]
    def verify_certificate_verify
      ct = @transcript[CT]
      certificate_pem = ct.certificate_list.first.cert_data.to_pem
      cv = @transcript[CV]
      signature_scheme = cv.signature_scheme
      signature = cv.signature
      context = 'TLS 1.3, server CertificateVerify'
      do_verify_certificate_verify(certificate_pem: certificate_pem,
                                   signature_scheme: signature_scheme,
                                   signature: signature,
                                   context: context,
                                   message_range: CH..CT)
    end

    # @return [String]
    def sign_finished
      digest = CipherSuite.digest(@cipher_suite)
      ch_sh = transcript_hash(CH..SH)
      finished_key = @key_schedule.client_finished_key(ch_sh)
      do_sign_finished(digest: digest,
                       finished_key: finished_key,
                       message_range: CH..EOED)
    end

    # @return [Boolean]
    def verify_finished
      digest = CipherSuite.digest(@cipher_suite)
      ch_sh = transcript_hash(CH..SH)
      finished_key = @key_schedule.server_finished_key(ch_sh)
      signature = @transcript[SF].verify_data
      do_verify_finished(digest: digest,
                         finished_key: finished_key,
                         message_range: CH..CV,
                         signature: signature)
    end

    # NOTE:
    # This implementation supports only TLS 1.3,
    # so negotiated_tls_1_3? assumes that it sent ClientHello with:
    #     1. supported_versions == ["\x03\x04"]
    #     2. legacy_versions == ["\x03\x03"]
    #
    # @raise [TLS13::Error::TLSError]
    #
    # @return [Boolean]
    def negotiated_tls_1_3?
      sh = @transcript[SH]
      sh_sv = sh.extensions[Message::ExtensionType::SUPPORTED_VERSIONS]
                &.versions
      sh_r8 = sh.random[-8..]
      if sh_sv&.first == Message::ProtocolVersion::TLS_1_3 &&
         sh_r8 != DOWNGRADE_PROTECTION_TLS_1_2 &&
         sh_r8 != DOWNGRADE_PROTECTION_TLS_1_1
        true
      elsif sh_sv.nil?
        false
      else
        terminate(:illegal_parameter)
      end
    end

    # @return [Boolean]
    def echoed_legacy_session_id?
      @transcript[CH].legacy_session_id ==
        @transcript[SH].legacy_session_id_echo
    end

    # @return [Boolean]
    def offerd_cipher_suite?
      @transcript[CH].cipher_suites.include?(@transcript[SH].cipher_suite)
    end

    # @return [Boolean]
    def valid_compression_method?
      @transcript[SH].legacy_compression_method == "\x00"
    end
  end
  # rubocop: enable Metrics/ClassLength
end

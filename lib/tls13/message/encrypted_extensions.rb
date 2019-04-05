# encoding: ascii-8bit
# frozen_string_literal: true

module TLS13
  using Refinements
  module Message
    class EncryptedExtensions
      attr_reader :msg_type
      attr_reader :extensions

      # https://www.iana.org/assignments/tls-extensiontype-values/tls-extensiontype-values.xhtml#tls-extensiontype-values-1
      ALLOWED_EXTENSIONS = [
        ExtensionType::SERVER_NAME,
        ExtensionType::MAX_FRAGMENT_LENGTH,
        ExtensionType::SUPPORTED_GROUPS,
        ExtensionType::USE_SRTP,
        ExtensionType::HEARTBEAT,
        ExtensionType::APPLICATION_LAYER_PROTOCOL_NEGOTIATION,
        ExtensionType::CLIENT_CERTIFICATE_TYPE,
        ExtensionType::SERVER_CERTIFICATE_TYPE,
        ExtensionType::RECORD_SIZE_LIMIT,
        ExtensionType::EARLY_DATA
      ].freeze

      # @param extensions [TLS13::Message::Extensions]
      def initialize(extensions = Extensions.new)
        @msg_type = HandshakeType::ENCRYPTED_EXTENSIONS
        @extensions = extensions || Extensions.new
      end

      # @return [String]
      def serialize
        @msg_type + @extensions.serialize.prefix_uint24_length
      end

      alias fragment serialize

      # @param binary [String]
      #
      # @raise [TLS13::Error::TLSError]
      #
      # @return [TLS13::Message::EncryptedExtensions]
      def self.deserialize(binary)
        raise Error::TLSError, :internal_error if binary.nil?
        raise Error::TLSError, :decode_error if binary.length < 6
        raise Error::TLSError, :internal_error \
          unless binary[0] == HandshakeType::ENCRYPTED_EXTENSIONS

        ee_len = Convert.bin2i(binary.slice(1, 3))
        exs_len = Convert.bin2i(binary.slice(4, 2))
        extensions = Extensions.deserialize(binary.slice(6, exs_len),
                                            HandshakeType::ENCRYPTED_EXTENSIONS)
        raise Error::TLSError, :decode_error \
          unless exs_len + 2 == ee_len && exs_len + 6 == binary.length

        EncryptedExtensions.new(extensions)
      end

      # @return [Boolean]
      def any_forbidden_extensions?
        !(@extensions.keys - ALLOWED_EXTENSIONS).empty?
      end
    end
  end
end

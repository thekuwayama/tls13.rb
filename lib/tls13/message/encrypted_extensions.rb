# encoding: ascii-8bit
# frozen_string_literal: true

module TLS13
  using Refinements
  module Message
    class EncryptedExtensions
      attr_reader :msg_type
      attr_reader :extensions

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
      # @raise [TLS13::Error::InternalError, TLSError]
      #
      # @return [TLS13::Message::EncryptedExtensions]
      def self.deserialize(binary)
        raise Error::InternalError if binary.nil?
        raise Error::TLSError, :decode_error if binary.length < 6
        raise Error::InternalError \
          unless binary[0] == HandshakeType::ENCRYPTED_EXTENSIONS

        ee_len = Convert.bin2i(binary.slice(1, 3))
        exs_len = Convert.bin2i(binary.slice(4, 2))
        extensions = Extensions.deserialize(binary.slice(6, exs_len),
                                            HandshakeType::ENCRYPTED_EXTENSIONS)
        raise Error::TLSError, :decode_error \
          unless exs_len + 2 == ee_len && exs_len + 6 == binary.length

        EncryptedExtensions.new(extensions)
      end
    end
  end
end

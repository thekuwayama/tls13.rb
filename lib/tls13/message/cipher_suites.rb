# encoding: ascii-8bit
# frozen_string_literal: true

module TLS13
  module Message
    module CipherSuite
      TLS_AES_128_GCM_SHA256       = "\x13\x01"
      TLS_AES_256_GCM_SHA384       = "\x13\x02"
      TLS_CHACHA20_POLY1305_SHA256 = "\x13\x03"
      TLS_AES_128_CCM_SHA256       = "\x13\x04"
      TLS_AES_128_CCM_8_SHA256     = "\x13\x05"
    end

    DEFALT_CIPHER_SUITES = [CipherSuite::TLS_AES_256_GCM_SHA384,
                            CipherSuite::TLS_CHACHA20_POLY1305_SHA256,
                            CipherSuite::TLS_AES_128_GCM_SHA256].freeze

    class CipherSuites
      attr_accessor :cipher_suites

      # @param cipher_suites [Array of CipherSuite]
      def initialize(cipher_suites = DEFALT_CIPHER_SUITES)
        @cipher_suites = cipher_suites || []
      end

      # @return [Integer]
      def length
        @cipher_suites.length * 2
      end

      # @return [String]
      def serialize
        binary = ''
        binary += i2uint16(length)
        binary += @cipher_suites.join
        binary
      end

      # @param binary [String]
      #
      # @raise [RuntimeError]
      #
      # @return [TLS13::Message::CipherSuites]
      def self.deserialize(binary)
        raise 'too short binary' if binary.nil?

        cipher_suites = []
        itr = 0
        while itr < binary.length
          cipher_suites << binary.slice(itr, 2)
          itr += 2
        end
        raise 'malformed binary' unless itr == binary.length

        CipherSuites.new(cipher_suites)
      end
    end
  end
end

# encoding: ascii-8bit
# frozen_string_literal: true

module TLS13
  using Refinements

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

  class Transcript < Hash
    def initialize
      super
    end

    # @param digest [String] name of digest algorithm
    # @param end_index [Integer]
    #
    # @return [String]
    def hash(digest, end_index)
      s = concat_messages(digest, end_index)
      OpenSSL::Digest.digest(digest, s)
    end

    # @param digest [String] name of digest algorithm
    # @param end_index [Integer]
    # @param truncate_bytes [Integer]
    #
    # @return [String]
    def truncate_hash(digest, end_index, truncate_bytes)
      s = concat_messages(digest, end_index)
      truncated = s[0...-truncate_bytes]
      OpenSSL::Digest.digest(digest, truncated)
    end

    private

    # @param digest [String] name of digest algorithm
    # @param end_index [Integer]
    #
    # @return [String]
    def concat_messages(digest, end_index)
      exc_prefix = ''
      if include?(HRR)
        # as an exception to the general rule
        exc_prefix = Message::HandshakeType::MESSAGE_HASH \
                     + "\x00\x00" \
                     + OpenSSL::Digest.new(digest).digest_length.to_uint8 \
                     + OpenSSL::Digest.digest(digest, self[CH1].serialize) \
                     + self[HRR].serialize
      end

      messages = (CH..end_index).to_a.map do |m|
        include?(m) ? self[m].serialize : ''
      end
      exc_prefix + messages.join
    end
  end
end

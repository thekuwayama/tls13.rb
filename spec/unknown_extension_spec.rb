# encoding: ascii-8bit
# frozen_string_literal: true

require_relative 'spec_helper'
using Refinements

RSpec.describe UnknownExtension do
  context 'valid uknown extension, no extension_data' do
    let(:extension) do
      UnknownExtension.new(extension_type: "\x8a\x8a")
    end

    it 'should be generated' do
      expect(extension.extension_type).to eq "\x8a\x8a"
      expect(extension.extension_data).to be_empty
    end

    it 'should be serialized' do
      expect(extension.serialize).to eq "\x8a\x8a" + ''.prefix_uint16_length
    end
  end

  context 'valid uknown extension' do
    let(:random_bytes) do
      OpenSSL::Random.random_bytes(20)
    end

    let(:extension) do
      UnknownExtension.new(extension_type: "\x8a\x8a",
                           extension_data: random_bytes)
    end

    it 'should be generated' do
      expect(extension.extension_type).to eq "\x8a\x8a"
      expect(extension.extension_data).to eq random_bytes
    end

    it 'should be serialized' do
      expect(extension.serialize).to eq "\x8a\x8a" \
                                        + random_bytes.prefix_uint16_length
    end
  end

  context 'invalid uknown extension, no extension_type,' do
    let(:extension) do
      UnknownExtension.new
    end

    it 'should not be generated' do
      expect { extension }.to raise_error(ArgumentError)
    end
  end

  context 'valid uknown extension binary, binary is nil,' do
    let(:extension) do
      UnknownExtension.deserialize(nil, "\x8a\x8a")
    end

    it 'should generate valid object' do
      expect(extension.extension_type).to eq "\x8a\x8a"
      expect(extension.extension_data).to be_empty
    end
  end

  context 'valid uknown extension binary, binary is empty,' do
    let(:extension) do
      UnknownExtension.deserialize([], "\x8a\x8a")
    end

    it 'should generate valid object' do
      expect(extension.extension_type).to eq "\x8a\x8a"
      expect(extension.extension_data).to be_empty
    end
  end

  context 'valid uknown extension binary' do
    let(:random_bytes) do
      OpenSSL::Random.random_bytes(20)
    end

    let(:extension) do
      UnknownExtension.deserialize(random_bytes, "\x8a\x8a")
    end

    it 'should generate valid object' do
      expect(extension.extension_type).to eq "\x8a\x8a"
      expect(extension.extension_data).to eq random_bytes
    end
  end
end

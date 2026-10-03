# frozen_string_literal: true

# A tiny Ruby fixture for the full grammar set.
module Acme
  # The largest size a store holds.
  MAX_SIZE = 64

  # A key-value store.
  # Keeps entries in a hash.
  class Store < Base
    attr_reader :entries

    # Builds an empty store.
    def initialize
      @entries = {}
    end

    # Adds a value under a key.
    def add(key, value)
      helper = ->(x) { x }
      @entries[key] = helper.call(value)
    end

    def self.empty
      new
    end

    class << self
      def build; end
    end

    alias put add
  end

  module Helpers
    def self.assist; end
  end
end

class Acme::Shape
  def area = 0
end

# Doubles a number.
def double(n)
  n * 2
end

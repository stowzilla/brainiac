# frozen_string_literal: true

module Brainiac
  # A collection of Ruby developer jokes with a clean class interface.
  #
  # @example Get a random joke
  #   Brainiac::Joke.random.tell
  #
  # @example Create a custom joke
  #   joke = Brainiac::Joke.new(setup: "Why do Ruby devs love hashes?", punchline: "Because they're key!")
  #   joke.tell
  class Joke
    # Built-in Ruby developer jokes
    JOKES = [
      { setup: "Why do Ruby developers prefer dark mode?", punchline: "Because light attracts bugs." },
      { setup: "What's a Ruby dev's favorite gem?", punchline: "The one that doesn't have breaking changes." },
      { setup: "Why did the Ruby developer quit their job?", punchline: "They didn't get arrays." },
      { setup: "How do Ruby developers exercise?", punchline: "They run benchmarks." },
      { setup: "Why was the Ruby hash feeling lonely?", punchline: "It lost its keys." },
      { setup: "What do you call a Ruby method with no arguments?", punchline: "Pointless." },
      { setup: "Why did the Ruby object break up with nil?", punchline: "It found the relationship too empty." },
      { setup: "What's a Rubyist's least favorite day?", punchline: "Garbage collection day." },
      { setup: "Why do Ruby blocks always get invited to parties?", punchline: "Because they yield to everyone." },
      { setup: "What did the Ruby dev say to the Python dev?", punchline: "Your whitespace is showing." }
    ].freeze

    attr_reader :setup, :punchline

    # @param setup [String] the joke setup line
    # @param punchline [String] the punchline
    def initialize(setup:, punchline:)
      @setup = setup
      @punchline = punchline
    end

    # Returns a random joke from the built-in collection.
    # @return [Joke]
    def self.random
      data = JOKES.sample
      new(setup: data[:setup], punchline: data[:punchline])
    end

    # Returns all built-in jokes.
    # @return [Array<Joke>]
    def self.all
      JOKES.map { |data| new(setup: data[:setup], punchline: data[:punchline]) }
    end

    # Returns the number of built-in jokes.
    # @return [Integer]
    def self.count
      JOKES.length
    end

    # Delivers the full joke (setup + punchline).
    # @return [String]
    def tell
      "#{setup} #{punchline}"
    end

    # Whether this joke is funny (spoiler: always yes).
    # @return [Boolean]
    def funny?
      true
    end

    # @return [String]
    def to_s
      tell
    end
  end
end

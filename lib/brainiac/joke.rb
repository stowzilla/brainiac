# frozen_string_literal: true

module Brainiac
  # A class that tells Ruby developer jokes.
  #
  # Usage:
  #   joke = Brainiac::Joke.random
  #   joke.tell  # => "Why do Ruby devs never get lost? — Because they always follow the right path."
  #
  #   custom = Brainiac::Joke.new(setup: "Why did the Rubyist quit?", punchline: "Too many blocks.")
  #   custom.funny?  # => true (always)
  #
  class Joke
    JOKES = [
      { setup: "Why do Ruby developers prefer dark mode?", punchline: "Because light attracts bugs." },
      { setup: "Why did the Ruby developer go broke?", punchline: "Because he used up all his cache." },
      { setup: "What's a Ruby developer's favorite gem?", punchline: "A diamond... but they'll settle for bundler." },
      { setup: "Why do Rubyists never get lost?", punchline: "Because they always follow the right path." },
      { setup: "How do Ruby developers break up?", punchline: "'It's not you, it's your nil values.'" },
      { setup: "Why was the Ruby developer so calm?", punchline: "Because everything was an object, even their feelings." },
      { setup: "What did the Ruby hash say to the array?", punchline: "'At least I have keys to my place.'" },
      { setup: "Why don't Ruby developers use stairs?", punchline: "They prefer to yield." },
      { setup: "What's a Ruby developer's least favorite chore?", punchline: "Taking out the garbage collector." },
      { setup: "Why did the junior dev mass-assign everything?", punchline: "Because attr_accessor was the only spell they knew." }
    ].freeze

    attr_reader :setup, :punchline

    # Create a joke — custom or randomly selected from built-ins.
    #
    # @param setup [String, nil] the joke setup (question)
    # @param punchline [String, nil] the punchline (answer)
    def initialize(setup: nil, punchline: nil)
      if setup && punchline
        @setup = setup
        @punchline = punchline
      else
        joke = JOKES.sample
        @setup = joke[:setup]
        @punchline = joke[:punchline]
      end
    end

    # Tell the joke (formatted output).
    # @return [String]
    def tell
      "#{@setup} — #{@punchline}"
    end

    alias to_s tell

    # Is this joke funny? (Yes. Always yes.)
    # @return [Boolean]
    def funny?
      true
    end

    # Pick a random joke.
    # @return [Brainiac::Joke]
    def self.random
      new
    end

    # All built-in jokes as Joke instances.
    # @return [Array<Brainiac::Joke>]
    def self.all
      JOKES.map { |j| new(setup: j[:setup], punchline: j[:punchline]) }
    end

    # Number of built-in jokes.
    # @return [Integer]
    def self.count
      JOKES.length
    end
  end
end

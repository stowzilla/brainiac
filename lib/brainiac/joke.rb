module Brainiac
  class Joke
    JOKES = [
      { setup: "Why do Ruby developers prefer dark mode?", punchline: "Because light attracts bugs." },
      { setup: "What's a Ruby developer's favorite gem?", punchline: "The one that actually installs without native extensions." },
      { setup: "Why did the Ruby developer quit their job?", punchline: "Because they didn't get arrays." },
      { setup: "How do Ruby objects greet each other?", punchline: "They send messages." },
      { setup: "Why do Ruby developers love blocks?", punchline: "Because they yield great results." },
      { setup: "What did the Hash say to the Array?", punchline: "You have no class." },
      { setup: "Why was the Ruby developer always calm?", punchline: "Because everything is an object — even their problems." },
      { setup: "What's a Ruby dev's least favorite kitchen appliance?", punchline: "The garbage collector." },
      { setup: "Why don't Ruby developers get lonely?", punchline: "Because they always have self." },
      { setup: "What do you call a frozen string in Ruby?", punchline: "Immutable evidence." }
    ].freeze

    attr_reader :setup, :punchline

    def initialize(setup: nil, punchline: nil)
      if setup && punchline
        @setup = setup
        @punchline = punchline
      else
        joke = self.class.random_joke
        @setup = joke[:setup]
        @punchline = joke[:punchline]
      end
    end

    def tell
      "#{@setup}\n#{@punchline}"
    end

    def to_s
      tell
    end

    def funny?
      true # All jokes are funny. Fight me.
    end

    def self.random_joke
      JOKES.sample
    end

    def self.random
      new
    end

    def self.all
      JOKES.map { |j| new(setup: j[:setup], punchline: j[:punchline]) }
    end

    def self.count
      JOKES.length
    end
  end
end

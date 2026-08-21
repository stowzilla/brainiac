module Brainiac
  module Greeting
    # Returns a greeting string for the given name.
    #
    # @param name [String] the name to greet (default: "World")
    # @return [String] the formatted greeting
    def self.hello(name = "World")
      name = "World" if name.nil? || name.strip.empty?
      "Hello, #{name}!"
    end
  end
end

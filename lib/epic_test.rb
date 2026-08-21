# frozen_string_literal: true

module EpicTest
  def self.greet(name)
    name = name.to_s.strip
    name = "stranger" if name.empty?
    "Hello, #{name}!"
  end
end

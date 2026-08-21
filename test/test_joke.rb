# frozen_string_literal: true

require_relative "test_helper"
require_relative "../lib/brainiac/joke"

class TestJoke < Minitest::Test
  def test_random_returns_a_joke
    joke = Brainiac::Joke.random
    assert_instance_of Brainiac::Joke, joke
  end

  def test_joke_has_setup_and_punchline
    joke = Brainiac::Joke.random
    refute_nil joke.setup
    refute_nil joke.punchline
    refute_empty joke.setup
    refute_empty joke.punchline
  end

  def test_tell_formats_joke
    joke = Brainiac::Joke.new(setup: "Why?", punchline: "Because.")
    assert_equal "Why? — Because.", joke.tell
  end

  def test_to_s_is_same_as_tell
    joke = Brainiac::Joke.new(setup: "Q", punchline: "A")
    assert_equal joke.tell, joke.to_s
  end

  def test_funny_is_always_true
    joke = Brainiac::Joke.random
    assert joke.funny?
  end

  def test_custom_joke
    joke = Brainiac::Joke.new(setup: "Knock knock", punchline: "Ruby who?")
    assert_equal "Knock knock", joke.setup
    assert_equal "Ruby who?", joke.punchline
  end

  def test_all_returns_array_of_jokes
    jokes = Brainiac::Joke.all
    assert_instance_of Array, jokes
    assert(jokes.all?(Brainiac::Joke))
  end

  def test_count_matches_built_in_jokes
    assert_equal 10, Brainiac::Joke.count
    assert_equal Brainiac::Joke.count, Brainiac::Joke.all.length
  end

  def test_all_jokes_have_content
    Brainiac::Joke.all.each do |joke|
      refute_empty joke.setup, "Joke setup should not be empty"
      refute_empty joke.punchline, "Joke punchline should not be empty"
    end
  end

  def test_random_picks_from_built_ins
    setups = Brainiac::Joke::JOKES.map { |j| j[:setup] }
    joke = Brainiac::Joke.random
    assert_includes setups, joke.setup
  end
end

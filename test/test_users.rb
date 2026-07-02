# frozen_string_literal: true

require_relative "test_helper"

class TestUsers < Minitest::Test
  def test_find_user_by_discord_id
    user = find_user_by_discord_id("397928984232591361")
    assert user
    assert_equal "Andy Davis", user["canonical_name"]
  end

  def test_find_user_by_discord_id_not_found
    assert_nil find_user_by_discord_id("000000000000000000")
  end

  def test_find_user_by_discord_username
    user = find_user_by_discord_username("fladamd")
    assert user
    assert_equal "Adam Dalton", user["canonical_name"]
  end

  def test_find_user_by_github_username
    user = find_user_by_github_username("ardavis")
    assert user
    assert_equal "Andy Davis", user["canonical_name"]
  end

  def test_find_user_by_canonical_name
    user = find_user_by_canonical_name("Galen")
    assert user
    assert_equal "1475925968584573181", user.dig("identities", "discord", "user_id")
  end

  def test_find_user_by_canonical_name_case_insensitive
    user = find_user_by_canonical_name("andy davis")
    assert user
    assert_equal "Andy Davis", user["canonical_name"]
  end

  def test_find_user_generic_by_discord_id
    user = find_user("832331260088287242")
    assert_equal "Adam Dalton", user["canonical_name"]
  end

  def test_find_user_generic_by_github
    user = find_user("dalton")
    assert_equal "Adam Dalton", user["canonical_name"]
  end

  def test_find_user_returns_nil_for_unknown
    assert_nil find_user("totally-unknown-person")
  end
end

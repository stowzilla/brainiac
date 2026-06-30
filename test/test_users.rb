# frozen_string_literal: true

require_relative "test_helper"

CONFIG_MTIMES = {} unless defined?(CONFIG_MTIMES)

def file_changed?(path, force: false) = true

# Write a test users registry to the path users.rb will use
users_path = File.join(BRAINIAC_DIR, "users.json")
File.write(users_path, JSON.generate({
  "users" => [
    {
      "canonical_name" => "Andy Davis",
      "identities" => {
        "discord" => { "username" => "ardavis", "user_id" => "397928984232591361" },
        "github" => { "username" => "ardavis" },
        "fizzy" => { "username" => "andy-davis" }
      },
      "aliases" => ["Andy"],
      "notes" => "Primary user"
    },
    {
      "canonical_name" => "Adam Dalton",
      "identities" => {
        "discord" => { "username" => "fladamd", "user_id" => "832331260088287242" },
        "github" => { "username" => "dalton" },
        "fizzy" => { "username" => "adam-dalton" }
      },
      "aliases" => [],
      "notes" => "Co-founder"
    },
    {
      "canonical_name" => "Galen",
      "identities" => {
        "discord" => { "username" => "galen-bot", "user_id" => "1475925968584573181" }
      },
      "aliases" => [],
      "notes" => "AI Agent"
    }
  ],
  "schema_version" => "1.0"
}))

require_relative "../lib/brainiac/users"

class TestUsers < Minitest::Test
  # --- Load registry ---

  def test_load_user_registry_loads_users
    registry = load_user_registry
    assert_equal 3, registry["users"].size
  end

  # --- Find by Discord ID ---

  def test_find_user_by_discord_id
    user = find_user_by_discord_id("397928984232591361")
    assert user
    assert_equal "Andy Davis", user["canonical_name"]
  end

  def test_find_user_by_discord_id_not_found
    assert_nil find_user_by_discord_id("000000000000000000")
  end

  # --- Find by Discord username ---

  def test_find_user_by_discord_username
    user = find_user_by_discord_username("fladamd")
    assert user
    assert_equal "Adam Dalton", user["canonical_name"]
  end

  # --- Find by GitHub username ---

  def test_find_user_by_github_username
    user = find_user_by_github_username("ardavis")
    assert user
    assert_equal "Andy Davis", user["canonical_name"]
  end

  def test_find_user_by_github_username_not_found
    assert_nil find_user_by_github_username("nobody")
  end

  # --- Find by Fizzy username ---

  def test_find_user_by_fizzy_username
    user = find_user_by_fizzy_username("adam-dalton")
    assert user
    assert_equal "Adam Dalton", user["canonical_name"]
  end

  # --- Find by canonical name ---

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

  # --- Generic find_user ---

  def test_find_user_by_discord_id_path
    user = find_user("832331260088287242")
    assert_equal "Adam Dalton", user["canonical_name"]
  end

  def test_find_user_by_discord_username_path
    user = find_user("ardavis")
    assert_equal "Andy Davis", user["canonical_name"]
  end

  def test_find_user_by_github_path
    user = find_user("dalton")
    assert_equal "Adam Dalton", user["canonical_name"]
  end

  def test_find_user_by_fizzy_path
    user = find_user("andy-davis")
    assert_equal "Andy Davis", user["canonical_name"]
  end

  def test_find_user_returns_nil_for_unknown
    assert_nil find_user("totally-unknown-person")
  end
end

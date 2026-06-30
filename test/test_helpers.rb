# frozen_string_literal: true

require_relative "test_helper"

# Stub the constants that config.rb and helpers.rb define
AI_AGENT_NAME = "Galen" unless defined?(AI_AGENT_NAME)
FIZZY_WEBHOOK_SECRET = "test-fizzy-secret" unless defined?(FIZZY_WEBHOOK_SECRET)
BRAINIAC_CONFIG = {} unless defined?(BRAINIAC_CONFIG)
CONFIG_MTIMES = {} unless defined?(CONFIG_MTIMES)
NOTIFICATION_COMMAND = nil unless defined?(NOTIFICATION_COMMAND)
DISCORD_ENABLED = false unless defined?(DISCORD_ENABLED)
AUTHORIZED_USER_IDS = ["user-1", "user-2", "agent-1"] unless defined?(AUTHORIZED_USER_IDS)
MERGED_CARDS = {} unless defined?(MERGED_CARDS)
MERGED_CARDS_MUTEX = Mutex.new unless defined?(MERGED_CARDS_MUTEX)
FIZZY_CONFIG = {
  "authorized_users" => [
    { "id" => "user-1", "name" => "Andy", "human" => true },
    { "id" => "user-2", "name" => "Adam", "human" => true },
    { "id" => "agent-1", "name" => "Galen", "human" => false }
  ],
  "boards" => {
    "development" => {
      "board_id" => "board-123",
      "webhook_secret" => "dev-board-secret",
      "columns" => { "right_now" => "col-1", "needs_review" => "col-2" }
    }
  }
} unless defined?(FIZZY_CONFIG)
FIZZY_BOARDS = FIZZY_CONFIG["boards"] || {} unless defined?(FIZZY_BOARDS)
GITHUB_CONFIG = { "webhook_secret" => "github-test-secret" } unless defined?(GITHUB_CONFIG)
PROJECTS = {
  "marketplace" => {
    "repo_path" => "/home/test/Code/marketplace",
    "fizzy_tags" => ["marketplace", "mp"],
    "github_repo" => "stowzilla/marketplace",
    "agent_cli" => "kiro-cli",
    "agent_cli_args" => "chat --no-interactive",
    "agent_model_flag" => "--model",
    "allowed_models" => {
      "opus" => "claude-opus-4.6",
      "sonnet" => "claude-sonnet-4.6",
      "haiku" => "claude-haiku-4.5",
      "deepseek" => "deepseek-3.2",
      "auto" => "auto"
    }
  },
  "brainiac" => {
    "repo_path" => "/home/test/Code/brainiac",
    "fizzy_tags" => ["brainiac"],
    "github_repo" => "stowzilla/brainiac",
    "default" => true
  }
} unless defined?(PROJECTS)

DEFAULT_PROJECT = {
  "repo_path" => Dir.pwd,
  "fizzy_tags" => [],
  "github_repo" => nil,
  "agent_cli" => "kiro-cli",
  "agent_cli_args" => "chat --no-interactive",
  "agent_model_flag" => "--model",
  "agent_model" => nil,
  "agent_effort_flag" => "--effort",
  "agent_effort" => nil,
  "allowed_models" => {
    "opus" => "claude-opus-4.6", "sonnet" => "claude-sonnet-4.6",
    "haiku" => "claude-haiku-4.5", "auto" => "auto"
  },
  "allowed_efforts" => %w[low medium high xhigh max]
}.freeze unless defined?(DEFAULT_PROJECT)

AGENT_REGISTRY = {
  "galen" => { "fizzy_name" => "Galen", "local" => true, "env" => { "FIZZY_TOKEN" => "tok" } },
  "glados" => { "fizzy_name" => "GLaDOS", "local" => true, "env" => {} }
} unless defined?(AGENT_REGISTRY)

CLI_PROVIDERS_DIR = File.join(BRAINIAC_DIR, "cli-providers") unless defined?(CLI_PROVIDERS_DIR)
FileUtils.mkdir_p(CLI_PROVIDERS_DIR)

# Stub minimal functions needed (only if not already loaded)
unless defined?(@helpers_stubs_defined)
  def discover_kiro_agents = []
  def all_agent_names = Set.new(["Galen", "GLaDOS"])
  def fizzy_display_name(n) = n
  def fizzy_env_for(n) = {}
  def fizzy_token_for(n) = "tok"
  def default_fizzy_env = {}
  def agent_cli_provider_for(n) = nil
  def agent_env_for(n) = {}
  @helpers_stubs_defined = true
end

require_relative "../lib/brainiac/helpers"

class TestHelpers < Minitest::Test
  # --- Slugify ---

  def test_slugify_basic
    assert_equal "hello-world", slugify("Hello World")
  end

  def test_slugify_strips_special_chars
    assert_equal "fix-bug-in-login", slugify("Fix bug in login!")
  end

  def test_slugify_truncates_to_max_length
    long_title = "a" * 100
    result = slugify(long_title, max_length: 40)
    assert_operator result.length, :<=, 40
  end

  def test_slugify_removes_trailing_hyphen
    assert_equal "hello", slugify("hello-!@#$%")
  end

  # --- Project identification by tags ---

  def test_identify_project_by_tags_marketplace
    tags = [{ "name" => "marketplace" }]
    key, config = identify_project_by_tags(tags)
    assert_equal "marketplace", key
    assert_equal "/home/test/Code/marketplace", config["repo_path"]
  end

  def test_identify_project_by_tags_short_alias
    tags = [{ "name" => "mp" }]
    key, _config = identify_project_by_tags(tags)
    assert_equal "marketplace", key
  end

  def test_identify_project_by_tags_case_insensitive
    tags = [{ "name" => "Marketplace" }]
    key, _config = identify_project_by_tags(tags)
    assert_equal "marketplace", key
  end

  def test_identify_project_by_tags_falls_back_to_default
    tags = [{ "name" => "unknown-tag" }]
    key, _config = identify_project_by_tags(tags)
    assert_equal "brainiac", key # default project
  end

  def test_identify_project_by_tags_string_tags
    tags = ["brainiac"]
    key, _config = identify_project_by_tags(tags)
    assert_equal "brainiac", key
  end

  # --- Project identification by repo ---

  def test_identify_project_by_repo
    key, config = identify_project_by_repo("stowzilla/marketplace")
    assert_equal "marketplace", key
    assert_equal "/home/test/Code/marketplace", config["repo_path"]
  end

  def test_identify_project_by_repo_not_found_falls_to_default
    key, _config = identify_project_by_repo("someorg/unknown-repo")
    assert_equal "brainiac", key
  end

  # --- Card map ---

  def test_load_card_map_empty_when_no_file
    FileUtils.rm_f(CARD_MAP_FILE)
    assert_equal({}, load_card_map)
  end

  def test_save_and_load_card_map
    map = { "card-abc" => { "number" => 42, "branch" => "fizzy-42-test" } }
    save_card_map(map)
    loaded = load_card_map
    assert_equal 42, loaded["card-abc"]["number"]
  end

  # --- Authorization ---

  def test_authorized_with_known_user
    payload = { "creator" => { "id" => "user-1", "name" => "Andy" } }
    assert authorized?(payload)
  end

  def test_not_authorized_with_unknown_user
    payload = { "creator" => { "id" => "unknown-999", "name" => "Hacker" } }
    refute authorized?(payload)
  end

  # --- Human mentioned ---

  def test_human_mentioned_true
    assert human_mentioned?("user-1")
  end

  def test_human_mentioned_false_for_agent
    refute human_mentioned?("agent-1")
  end

  def test_human_mentioned_false_for_unknown
    refute human_mentioned?("unknown-id")
  end

  # --- Model detection ---

  def test_detect_model_from_inline_text
    config = PROJECTS["marketplace"]
    assert_equal "claude-opus-4.6", detect_model(config, text: "[opus] do the thing")
  end

  def test_detect_model_from_tags
    config = PROJECTS["marketplace"]
    assert_equal "claude-sonnet-4.6", detect_model(config, tags: [{ "name" => "sonnet" }])
  end

  def test_detect_model_unknown_tag_ignored
    config = PROJECTS["marketplace"]
    # "unknown" isn't in allowed_models, so it returns default
    result = detect_model(config, tags: [{ "name" => "unknown" }])
    assert_nil result # falls through to agent_model which is nil for this project
  end

  def test_detect_model_text_priority_over_tags
    config = PROJECTS["marketplace"]
    result = detect_model(config, text: "[haiku] review", tags: [{ "name" => "opus" }])
    assert_equal "claude-haiku-4.5", result
  end

  # --- Merged card tracking ---

  def test_mark_and_check_card_merged
    mark_card_merged(100)
    assert card_merged?(100)
  end

  def test_card_not_merged_initially
    refute card_merged?(999)
  end

  def test_card_merged_expires
    MERGED_CARDS_MUTEX.synchronize { MERGED_CARDS["200"] = Time.now - 700 }
    refute card_merged?(200)
  end

  # --- CLI provider ---

  def test_load_cli_provider_returns_empty_for_nil
    assert_equal({}, load_cli_provider(nil))
  end

  def test_load_cli_provider_returns_empty_for_missing_file
    assert_equal({}, load_cli_provider("nonexistent"))
  end

  def test_load_cli_provider_parses_json
    File.write(File.join(CLI_PROVIDERS_DIR, "grok.json"), JSON.generate({
      "binary" => "grok",
      "default_args" => "chat --yes",
      "model_flag" => "-m",
      "models" => { "default" => "grok-3" },
      "prompt_mode" => "flag",
      "prompt_flag" => "-p"
    }))
    result = load_cli_provider("grok")
    assert_equal "grok", result["agent_cli"]
    assert_equal "chat --yes", result["agent_cli_args"]
    assert_equal "-m", result["agent_model_flag"]
    assert_equal "flag", result["prompt_mode"]
    assert_equal "-p", result["prompt_flag"]
  end

  # --- Detect CLI provider from tags ---

  def test_detect_cli_provider_from_text
    assert_equal "grok", detect_cli_provider(text: "[cli:grok] do stuff")
  end

  def test_detect_cli_provider_from_tags
    assert_equal "grok", detect_cli_provider(tags: [{ "name" => "cli-grok" }])
  end

  def test_detect_cli_provider_nil_when_absent
    assert_nil detect_cli_provider(text: "normal message", tags: [])
  end

  # --- Default project key ---

  def test_default_project_key
    assert_equal "brainiac", default_project_key
  end
end

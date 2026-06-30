# frozen_string_literal: true

require "minitest/autorun"
require "json"
require "tmpdir"
require "fileutils"
require "logger"
require "tempfile"
require "ostruct"

# Create a temporary brainiac directory for tests
TEST_BRAINIAC_DIR = Dir.mktmpdir("brainiac-test")

# Stub constants before loading any brainiac modules
BRAINIAC_DIR = TEST_BRAINIAC_DIR unless defined?(BRAINIAC_DIR)
PROJECTS_FILE = File.join(BRAINIAC_DIR, "projects.json") unless defined?(PROJECTS_FILE)
KIRO_AGENTS_DIR = File.join(BRAINIAC_DIR, "kiro-agents") unless defined?(KIRO_AGENTS_DIR)
CARD_MAP_FILE = File.join(BRAINIAC_DIR, "card_map.json") unless defined?(CARD_MAP_FILE)
AGENT_REGISTRY_FILE = File.join(BRAINIAC_DIR, "agents.json") unless defined?(AGENT_REGISTRY_FILE)
BRAINIAC_CONFIG_FILE = File.join(BRAINIAC_DIR, "brainiac.json") unless defined?(BRAINIAC_CONFIG_FILE)
BRAIN_BASE_DIR = File.join(BRAINIAC_DIR, "brain") unless defined?(BRAIN_BASE_DIR)
KNOWLEDGE_DIR = File.join(BRAIN_BASE_DIR, "knowledge") unless defined?(KNOWLEDGE_DIR)
PERSONA_BASE_DIR = File.join(BRAIN_BASE_DIR, "persona") unless defined?(PERSONA_BASE_DIR)
MEMORY_BASE_DIR = File.join(BRAIN_BASE_DIR, "memory") unless defined?(MEMORY_BASE_DIR)
KNOWLEDGE_COLLECTION = "brainiac-knowledge" unless defined?(KNOWLEDGE_COLLECTION)
ROLES_DIR = File.join(BRAINIAC_DIR, "roles") unless defined?(ROLES_DIR)
FIZZY_CONFIG_FILE = File.join(BRAINIAC_DIR, "fizzy.json") unless defined?(FIZZY_CONFIG_FILE)
GITHUB_CONFIG_FILE = File.join(BRAINIAC_DIR, "github.json") unless defined?(GITHUB_CONFIG_FILE)
USERS_FILE = File.join(BRAINIAC_DIR, "users.json") unless defined?(USERS_FILE)
LOG = Logger.new(File::NULL) unless defined?(LOG)

# Create directories
[BRAINIAC_DIR, KIRO_AGENTS_DIR, BRAIN_BASE_DIR, KNOWLEDGE_DIR, PERSONA_BASE_DIR,
 MEMORY_BASE_DIR, ROLES_DIR].each { |d| FileUtils.mkdir_p(d) }

# Add project root to load path
$LOAD_PATH.unshift File.expand_path("..", __dir__)
$LOAD_PATH.unshift File.expand_path("../lib", __dir__)

# Minitest hooks
Minitest.after_run { FileUtils.rm_rf(TEST_BRAINIAC_DIR) }

# frozen_string_literal: true

# Profiles: named bundles of environment variables that can be injected into an
# agent dispatch without standing up a separate agent.
#
# The canonical use case is kiro-cli multi-account: each AWS account gets its own
# XDG_DATA_HOME (separate auth store), and a profile lets you flip which account a
# dispatch runs against via an inline tag ([profile:X] / [p:X]) — same CLI, same
# agent, different credentials.
#
# Config lives at ~/.brainiac/profiles.json:
#
#   {
#     "q":  { "env": { "XDG_DATA_HOME": "/home/andy/.local/share" } },
#     "k+": { "env": { "XDG_DATA_HOME": "/home/andy/.brainiac/kiro-accounts/kiro-pro" }, "default": true }
#   }
#
# A profile may also optionally pin a model and/or cli_provider:
#
#   "k+": { "env": {...}, "model": "opus", "cli_provider": "kiro-pro" }
#
# Exactly one profile may be marked "default": true — it applies when no [profile:X]
# tag is present. Because it's only a fallback, an agent's own env (from agents.json)
# takes precedence over the default profile. An *explicitly requested* profile, by
# contrast, takes precedence over agent env — that's the whole point of asking for it.
#
# Precedence at the spawn point (highest wins):
#   explicit env passed to run_agent
#   > explicitly-requested profile env
#   > agent env (agents.json)
#   > default profile env
#   > DEFAULT_AGENT_ENV

PROFILES_FILE = File.join(BRAINIAC_DIR, "profiles.json")

def load_profiles_config
  return {} unless File.exist?(PROFILES_FILE)

  raw = JSON.parse(File.read(PROFILES_FILE))
  LOG.info "Loaded #{raw.size} profile(s) from #{PROFILES_FILE}" if defined?(LOG)

  # Normalize keys to lowercase for case-insensitive lookup, but preserve the
  # profile body as-is. Profile keys can contain '+' etc. (e.g. "k+").
  normalized = {}
  raw.each { |key, entry| normalized[key.to_s.downcase] = entry }
  normalized
rescue JSON::ParserError => e
  LOG.error "Failed to parse profiles.json: #{e.message}" if defined?(LOG)
  {}
end

PROFILES = load_profiles_config

def reload_profiles!(force: false)
  return unless file_changed?(PROFILES_FILE, force: force)

  PROFILES.replace(load_profiles_config)
  LOG.info "Reloaded profiles: #{PROFILES.keys.join(", ")}" if defined?(LOG)
end

# Look up a profile entry by name (case-insensitive). Returns the raw hash or nil.
def profile_entry(profile_name)
  return nil unless profile_name

  PROFILES[profile_name.to_s.downcase]
end

# Find the profile marked "default": true. Returns [name, entry] or nil.
def default_profile
  PROFILES.find { |_name, entry| entry.is_a?(Hash) && entry["default"] }
end

# Resolve the env hash contributed by a profile.
#
# When profile_name is given and matches a profile, returns that profile's env.
# When profile_name is nil, returns the default profile's env (or {}).
# When profile_name is given but unknown, returns {} (never silently falls back
# to the default — a typo shouldn't route a dispatch to the wrong account).
#
# The caller decides precedence relative to agent env — see profile_spawn_env.
def profile_env(profile_name)
  entry = profile_name ? profile_entry(profile_name) : default_profile&.last
  return {} unless entry.is_a?(Hash)

  (entry["env"] || {}).each_with_object({}) { |(k, v), h| h[k.to_s] = v.to_s }
end

# Compute the profile contribution to a spawn env, honoring precedence relative
# to agent env.
#
# - An explicitly-requested profile (profile_name present and known) layers ON TOP
#   of agent env — the request wins, so you can flip accounts for one dispatch.
# - The default profile (no profile_name given) layers UNDER agent env — it's only
#   a fallback for dispatches that didn't ask for anything.
# - An unknown profile name is ignored (agent env only) and logged, so a typo never
#   silently swaps accounts.
#
# Returns a merged env hash ready to be used as the base for further merges
# (e.g. run_agent's explicit `env:` still wins by merging afterward).
def profile_spawn_env(agent_env, profile_name)
  if profile_name
    if profile_entry(profile_name)
      # Explicit request: profile wins over agent env.
      agent_env.merge(profile_env(profile_name))
    else
      LOG.warn "Unknown profile '#{profile_name}' — ignoring (using agent env)" if defined?(LOG)
      agent_env
    end
  else
    # No profile requested: default profile is a baseline agent env overrides.
    default_env = profile_env(nil)
    return agent_env if default_env.empty?

    default_env.merge(agent_env)
  end
end

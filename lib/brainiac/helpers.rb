# frozen_string_literal: true

# Shared helpers: project identification, card map, run_cmd, run_agent, signatures, model detection.

require "English"
CLI_PROVIDERS_DIR = File.join(BRAINIAC_DIR, "cli-providers")

# Load a CLI provider config from ~/.brainiac/cli-providers/<name>.{toml,json}.
# Returns a hash with normalized keys, or {} if not found.
def load_cli_provider(provider_name)
  return {} unless provider_name

  provider_base = File.join(CLI_PROVIDERS_DIR, provider_name)
  resolved = Brainiac::ConfigLoader.resolve_path(provider_base)
  return {} unless resolved

  raw = Brainiac::ConfigLoader.load_file(resolved)
  config = {
    "agent_cli" => raw["binary"],
    "agent_cli_args" => raw["default_args"],
    "agent_model_flag" => raw["model_flag"],
    "agent_effort_flag" => raw["effort_flag"],
    "allowed_models" => raw["models"],
    "allowed_efforts" => raw["efforts"]
  }
  # agent_flag: how the agent identity is passed (default: "--agent").
  # Set to null/false in provider JSON to suppress passing agent name entirely.
  # We must preserve the key even when nil so merges don't lose the "no agent flag" intent.
  config["agent_flag"] = raw.key?("agent_flag") ? raw["agent_flag"] : "--agent"
  # prompt_mode: "stdin" (default) or "flag" — how the prompt is delivered.
  config["prompt_mode"] = raw["prompt_mode"] || "stdin"
  config["prompt_flag"] = raw["prompt_flag"] if raw["prompt_flag"]
  # resume_flag: when set, follow-up dispatches use this flag to continue the
  # most recent session in the working directory (e.g. "-c" or "--continue").
  config["resume_flag"] = raw["resume_flag"] if raw["resume_flag"]
  # Compact nil values except agent_flag (which uses nil to mean "don't pass agent name")
  agent_flag_value = config["agent_flag"]
  config.compact!
  config["agent_flag"] = agent_flag_value if raw.key?("agent_flag")
  config
rescue Brainiac::ConfigLoader::ParseError => e
  LOG.warn "Failed to parse CLI provider '#{provider_name}': #{e.message}"
  {}
end

# Resolve CLI config for a project by merging provider defaults with project overrides.
# Priority: cli_provider_override > agent-level cli_provider > project-level cli_provider > DEFAULT_PROJECT
def resolve_project_cli_config(project_config, cli_provider_override: nil, agent_name: nil)
  # Determine which CLI provider to use (priority: override > agent > project)
  provider_name = cli_provider_override
  provider_name ||= agent_cli_provider_for(agent_name) if agent_name
  provider_name ||= project_config["cli_provider"]

  provider_config = load_cli_provider(provider_name)

  DEFAULT_PROJECT.merge(provider_config).merge(project_config).tap do |resolved|
    # If an override or agent-level provider was used, it should win over the
    # project-level cli_provider's config. Re-apply the override provider on top.
    resolved.merge!(provider_config) if provider_name && provider_name != project_config["cli_provider"]
  end
end

# Get the cli_provider configured at the agent level in agents.json.
def agent_cli_provider_for(agent_name)
  return nil unless agent_name

  key = agent_name.downcase.gsub(/[^a-z0-9-]/, "-")
  entry = AGENT_REGISTRY[key]
  return nil unless entry.is_a?(Hash)

  entry["cli_provider"]
end

# Detect CLI provider override from inline [cli:X] tag or card tags.
# Returns the provider name (e.g. "grok") or nil.
def detect_cli_provider(text: "", tags: [])
  # Inline tag: [cli:grok] — works in any channel
  if (match = text.match(/\[cli:(\w+)\]/i))
    return match[1].downcase
  end

  # Plugin hook: let plugins detect from their own metadata (e.g., card tags)
  results = Brainiac.emit(:detect_cli_provider, text: text, tags: tags)
  plugin_result = results.compact.first
  return plugin_result if plugin_result

  nil
end

def default_project_key
  # Find the project marked as default
  default = PROJECTS.find { |_key, config| config["default"] == true }
  default ? default[0] : nil
end

def identify_project_by_repo(repo_full_name)
  return nil if PROJECTS.empty?

  PROJECTS.each do |project_key, config|
    return [project_key, config] if config["github_repo"] == repo_full_name
  end

  # Fall back to default project if configured
  default_key = default_project_key
  if default_key
    LOG.info "No project matched GitHub repo '#{repo_full_name}', falling back to default project '#{default_key}'"
    return [default_key, PROJECTS[default_key]]
  end

  nil
end

def load_work_item_map
  work_items_base = File.join(BRAINIAC_DIR, "work_items")
  raw = Brainiac::ConfigLoader.load(work_items_base, default: {})
  migrate_work_item_map(raw)
rescue StandardError
  {}
end

def save_work_item_map(map)
  File.write(WORK_ITEM_MAP_FILE, JSON.pretty_generate(map))
end

# Migrate old-format work item maps (keyed by Fizzy card internal ID with flat structure)
# to the new source-agnostic format (keyed by work item ID with sources hash).
# Old format: { "fizzy-uuid" => { "number" => 42, "branch" => "...", "worktree" => "...", "project" => "...", "agent" => "..." } }
# New format: { "wi-abc123" => { "id" => "wi-...", "branch" => "...", "worktree" => "...",
#   "project" => "...", "agent" => "...", "sources" => { "fizzy" => { ... } } } }
def migrate_work_item_map(raw)
  return raw if raw.empty?

  # Detect: if any entry has a "sources" key, it's already new format (or mixed)
  # If none have "sources", it's entirely old format
  needs_migration = raw.values.any? { |v| v.is_a?(Hash) && !v.key?("sources") }
  return raw unless needs_migration

  migrated = {}
  raw.each do |key, entry|
    next unless entry.is_a?(Hash)

    if entry.key?("sources")
      # Already new format
      migrated[key] = entry
    else
      # Old format — migrate. Generate a work item ID from the branch or card number.
      work_item_id = generate_work_item_id(branch: entry["branch"], card_number: entry["number"])
      migrated[work_item_id] = {
        "id" => work_item_id,
        "branch" => entry["branch"],
        "worktree" => entry["worktree"],
        "project" => entry["project"],
        "agent" => entry["agent"],
        "sources" => {
          "fizzy" => {
            "card_internal_id" => key,
            "card_number" => entry["number"]
          }
        }
      }
      # Preserve PR tracking if it exists
      migrated[work_item_id]["sources"]["github"] = { "prs" => entry["prs"] } if entry["prs"]
    end
  end
  migrated
end

# Generate a deterministic work item ID from available identifiers.
# Priority: branch name (universal join key), then card number fallback.
def generate_work_item_id(branch: nil, card_number: nil)
  if branch
    "wi-#{Digest::SHA256.hexdigest(branch)[0..7]}"
  elsif card_number
    "wi-card-#{card_number}"
  else
    "wi-#{SecureRandom.hex(4)}"
  end
end

# Find a work item by its branch name. Returns [work_item_id, info] or nil.
# This is the primary lookup method — branch is the universal join key.
def find_work_item_by_branch(branch)
  return nil unless branch

  map = load_work_item_map
  map.each do |work_item_id, info|
    next unless info.is_a?(Hash) && info["branch"] == branch

    return [work_item_id, info]
  end
  nil
end

# Find a work item by its ID. Returns the info hash or nil.
def find_work_item_by_id(work_item_id)
  return nil unless work_item_id

  map = load_work_item_map
  map[work_item_id]
end

# Find a work item by a Fizzy card internal ID (for backward compat with Fizzy plugin).
# Returns [work_item_id, info] or nil.
def find_work_item_by_card(card_internal_id)
  return nil unless card_internal_id

  map = load_work_item_map
  map.each do |work_item_id, info|
    next unless info.is_a?(Hash)

    fizzy_source = info.dig("sources", "fizzy")
    next unless fizzy_source && fizzy_source["card_internal_id"] == card_internal_id

    return [work_item_id, info]
  end
  nil
end

# Register a new work item or update an existing one.
# Returns the work item ID.
def register_work_item(branch:, worktree: nil, project: nil, agent: nil, source: nil, source_data: {})
  map = load_work_item_map

  # Check if a work item already exists for this branch
  existing_id = nil
  map.each do |wid, info|
    if info.is_a?(Hash) && info["branch"] == branch
      existing_id = wid
      break
    end
  end

  work_item_id = existing_id || generate_work_item_id(branch: branch)

  if existing_id
    # Update existing entry — merge in new source, update worktree/agent if provided
    map[work_item_id]["worktree"] = worktree if worktree
    map[work_item_id]["agent"] = agent if agent
    map[work_item_id]["sources"] ||= {}
    map[work_item_id]["sources"][source] = source_data if source
  else
    # Create new entry
    map[work_item_id] = {
      "id" => work_item_id,
      "branch" => branch,
      "worktree" => worktree,
      "project" => project,
      "agent" => agent,
      "sources" => source ? { source => source_data } : {}
    }
  end

  save_work_item_map(map)
  work_item_id
end

# Add or update a source on an existing work item.
# Returns true if the work item was found and updated, false otherwise.
def register_work_item_source(source:, source_data:, work_item_id: nil, branch: nil) # rubocop:disable Naming/PredicateMethod
  map = load_work_item_map

  # Find by ID or branch
  target_id = work_item_id
  unless target_id
    map.each do |wid, info|
      if info.is_a?(Hash) && info["branch"] == branch
        target_id = wid
        break
      end
    end
  end

  return false unless target_id && map[target_id]

  map[target_id]["sources"] ||= {}
  map[target_id]["sources"][source] = source_data
  save_work_item_map(map)
  true
end

def slugify(title, max_length: 40)
  title.downcase.gsub(/[^a-z0-9\s-]/, "").strip.gsub(/\s+/, "-").slice(0, max_length).chomp("-")
end

def run_cmd(*cmd, chdir:, env: {})
  LOG.info "Running: #{cmd.join(" ")} (in #{chdir})"
  stdout, stderr, status = Open3.capture3(env, *cmd, chdir: chdir)
  raise "Command failed (#{cmd.first}): #{stderr}" unless status.success?

  stdout
end

# Cards that have been merged to main — skip Needs Review moves for these.
# Keyed by card number (string), value is Time. Entries expire after 10 minutes.
MERGED_CARDS = {}
MERGED_CARDS_MUTEX = Mutex.new

def mark_work_item_merged(card_number)
  MERGED_CARDS_MUTEX.synchronize { MERGED_CARDS[card_number.to_s] = Time.now }
end

def work_item_merged?(card_number)
  MERGED_CARDS_MUTEX.synchronize do
    ts = MERGED_CARDS[card_number.to_s]
    ts && (Time.now - ts < 600)
  end
end

# Returns a formatted string suitable for injection into the prompt, or ''
# if the fetch fails (agent can still fetch manually as a fallback).
PREFETCH_COMMENT_LIMIT = 15
COMMENT_BODY_TRUNCATE_LENGTH = 500
CARD_CONTEXT_CACHE = {}
CARD_CONTEXT_CACHE_TTL = 60 # seconds

# Fetch recent comments for a card. Returns array of text parts.

# Extract the last N meaningful lines from an agent log for crash reporting.
def extract_crash_snippet(log_file, max_lines: 20)
  return nil unless log_file && File.exist?(log_file)

  lines = File.readlines(log_file).map { |l| l.gsub(/\e\[[0-9;]*[a-zA-Z]/, "").rstrip }.reject(&:empty?).last(max_lines)
  lines&.join("\n")
rescue StandardError => e
  LOG.warn "[CrashNotify] Could not read log: #{e.message}"
  nil
end

# Notify the originating channel that an agent crashed.
# source: :github, :discord, or plugin-registered sources
# source_context: hash with channel-specific info needed to post the notification
def notify_agent_crash(exit_status:, log_file:, agent_name:, source:, source_context:, project_config:)
  agent_display = agent_name || "Agent"
  snippet = extract_crash_snippet(log_file)

  # Emit to plugins — they handle their own channel-specific delivery
  handled = Brainiac.emit(:agent_crashed,
                          exit_status: exit_status, log_file: log_file, agent_name: agent_display,
                          source: source, source_context: source_context, project_config: project_config,
                          snippet: snippet)

  # If no plugin handled it, log a warning
  LOG.warn "[CrashNotify] Agent crashed but no plugin handled notification (source: #{source})" unless handled.any?
rescue StandardError => e
  LOG.error "[CrashNotify] Unexpected error: #{e.message}"
end

# Check if a prior CLI session exists in the given directory for the specified CLI binary.
# This prevents resume attempts when the CLI provider changed (e.g., [cli:grok] in a thread
# started by kiro-cli) or when the session was started on a different machine.
def prior_session_exists?(chdir, agent_cli)
  return false unless chdir && agent_cli

  cli_name = File.basename(agent_cli)

  # Check for CLI-specific session markers:
  # - grok uses .grok/ directory for session state
  # - kiro-cli uses .kiro-cli/ or similar
  # - Generic fallback: check tmp/ for agent logs from this CLI
  session_dir = File.join(chdir, ".#{cli_name}")
  return true if File.directory?(session_dir)

  # Fallback: look for recent session logs in tmp/ that suggest this CLI ran here before.
  # This covers CLIs that don't leave a dotdir but do leave logs via brainiac.
  tmp_dir = File.join(chdir, "tmp")
  return false unless File.directory?(tmp_dir)

  Dir.glob(File.join(tmp_dir, "agent-*.log")).any? do |log|
    # Only count logs from the last 24 hours as valid "resumable" sessions
    File.mtime(log) > Time.now - 86_400
  end
rescue StandardError
  false
end

# Public helper: check if resume is viable for a given project + CLI provider combo.
# Plugins should call this BEFORE building the prompt to decide between
# render_resume_prompt (lean) and render_prompt (full context).
#
# Returns true if the CLI supports resume AND a prior session exists in the working directory.
# When this returns false, plugins should use render_prompt with thread history as card_context
# so the agent gets full context even though this is a follow-up message.
def resume_viable?(project_config:, cli_provider: nil, agent_name: nil, chdir: nil)
  resolved = resolve_project_cli_config(project_config, cli_provider_override: cli_provider, agent_name: agent_name)
  chdir ||= resolved["repo_path"]
  return false unless resolved["resume_flag"]

  prior_session_exists?(chdir, resolved["agent_cli"])
end

# Determine whether a session resume should actually happen.
# Returns truthy (the resume flag string) if viable, false otherwise.
# Logs a message when resume was requested but isn't possible.
def resolve_resume(resume, resolved, chdir)
  return false unless resume && resolved["resume_flag"]
  return resolved["resume_flag"] if prior_session_exists?(chdir, resolved["agent_cli"])

  LOG.info "[Dispatch] Resume requested but not viable for #{resolved["agent_cli"]} in #{chdir} — starting fresh session"
  false
end

# Check if intent detection says to skip dispatching the agent.
# Returns true if the message should be skipped, false otherwise.
# Only runs if a raw message is provided, an agent is named, and intent is enabled.
def intent_skip?(message, agent_name:, source: nil, channel: nil, context: nil)
  return false unless message && agent_name && intent_config["enabled"]

  intent_channel = channel || source&.to_s || "conversation"
  unless check_intent(message, agent_name: agent_name, channel: intent_channel, context: context)
    LOG.info "[Intent] Skipping dispatch for #{agent_name} — message classified as not requiring response"
    return true
  end

  false
end

def run_agent(prompt, project_config:, chdir: nil, log_name: "agent", model: nil, effort: nil, agent_name: nil, card_number: nil, comment_id: nil,
              source: nil, source_context: {}, skip_column_move: false, cli_provider: nil, resume: false,
              message: nil, channel: nil, context: nil)
  # Intent gate: if a raw message is provided, check whether the agent should respond.
  return nil if intent_skip?(message, agent_name: agent_name, source: source, channel: channel, context: context)

  resolved = resolve_project_cli_config(project_config, cli_provider_override: cli_provider, agent_name: agent_name)
  chdir ||= resolved["repo_path"]
  model ||= resolved["agent_model"]
  effort ||= resolved["agent_effort"]
  agent_config_name = agent_name&.downcase&.gsub(/[^a-z0-9-]/, "-")

  # Auto-resume: only if the provider supports it AND a prior session exists for this CLI here.
  should_resume = resolve_resume(resume, resolved, chdir)

  # Pre-dispatch hook — plugins can prep the working directory (e.g., copy config files, clean up)
  Brainiac.emit(:pre_dispatch, chdir: chdir, project_config: project_config, agent_name: agent_name)

  timestamp = Time.now.strftime("%Y%m%d-%H%M%S")
  log_file = File.join(chdir, "tmp/agent-#{log_name}-#{timestamp}.log")
  FileUtils.mkdir_p(File.dirname(log_file))

  prompt_file = write_agent_prompt_file(prompt, log_name, timestamp)
  cmd = build_agent_cmd(resolved, agent_config_name: agent_config_name, model: model, effort: effort, prompt_file: prompt_file, resume: should_resume)
  prompt_mode = resolved["prompt_mode"] || "stdin"

  spawn_env = agent_env_for(agent_name)

  LOG.info "Running #{resolved["agent_cli"]} in #{chdir}, logging to #{log_file}"
  LOG.info "Prompt written to #{prompt_file}"
  LOG.info "Command: #{cmd.join(" ")}#{" (resuming session)" if should_resume}"
  LOG.info "Injecting #{spawn_env.size} env var(s) for agent #{agent_name}: #{spawn_env.keys.join(", ")}" unless spawn_env.empty?

  project_key_for_restart = PROJECTS.find { |_k, v| v == project_config }&.first
  head_before, status_before = capture_git_state(chdir) if project_key_for_restart == "brainiac"

  pid = spawn(spawn_env, *cmd,
              chdir: chdir,
              **(prompt_mode == "stdin" ? { in: prompt_file } : {}),
              out: [log_file, "w"],
              err: %i[child out])

  Thread.new do
    Process.wait(pid)
    handle_agent_completion(
      pid: pid, agent_cli: resolved["agent_cli"], agent_config_name: agent_config_name,
      agent_name: agent_name, log_file: log_file, log_name: log_name,
      prompt_file: prompt_file, chdir: chdir, source: source,
      source_context: source_context, project_config: project_config,
      card_number: card_number, skip_column_move: skip_column_move,
      head_before: head_before, status_before: status_before,
      project_key_for_restart: project_key_for_restart
    )
  end

  LOG.info "#{resolved["agent_cli"]} started (pid: #{pid}, agent: #{agent_config_name || "default"}, " \
           "model: #{model || "default"}), tail -f #{log_file}"

  [pid, log_file]
end

# Write agent prompt to a temp file, return path.
def write_agent_prompt_file(prompt, log_name, timestamp)
  prompt_dir = File.join(BRAINIAC_DIR, "tmp")
  FileUtils.mkdir_p(prompt_dir)
  prompt_file = File.join(prompt_dir, "prompt-#{log_name}-#{timestamp}.md")
  File.write(prompt_file, prompt)
  prompt_file
end

# Build the CLI command array for an agent invocation.
# When prompt_file is provided and prompt_mode is "flag", appends the prompt as a CLI argument.
# When resume is true and the provider has a resume_flag, adds it to continue the last session.
def build_agent_cmd(resolved, agent_config_name: nil, model: nil, effort: nil, prompt_file: nil, resume: false)
  cmd = [resolved["agent_cli"]]
  # agent_flag controls how the agent identity is passed. Defaults to "--agent".
  # Provider configs can set it to a different flag or null to suppress entirely.
  agent_flag = resolved.key?("agent_flag") ? resolved["agent_flag"] : "--agent"
  cmd.push(agent_flag, agent_config_name) if agent_flag && agent_config_name
  cmd.concat(resolved["agent_cli_args"].split)
  # Only pass --model if the model is a valid ID for this provider.
  # "auto" means "let the CLI choose" — skip passing it unless the provider explicitly maps it.
  if model && resolved["agent_model_flag"] && !resolved["agent_model_flag"].empty?
    allowed = resolved["allowed_models"] || {}
    # Pass the model if it's a mapped value (e.g. "claude-opus-4.6") or the key itself is mapped
    is_known = allowed.value?(model) || allowed.key?(model)
    cmd.push(resolved["agent_model_flag"], model) if is_known
  end
  cmd.push(resolved["agent_effort_flag"], effort) if resolved["agent_effort_flag"] && !resolved["agent_effort_flag"].empty? && effort
  # Resume the most recent session in the working directory (for multi-turn CLIs like grok)
  cmd.push(resolved["resume_flag"]) if resume && resolved["resume_flag"]
  # prompt_mode: "flag" passes the prompt file path via the configured prompt_flag (e.g. --prompt-file).
  cmd.push(resolved["prompt_flag"], prompt_file) if prompt_file && resolved["prompt_mode"] == "flag" && resolved["prompt_flag"]
  cmd
end

def handle_agent_completion(**ctx)
  agent_exit_status = $CHILD_STATUS.exitstatus
  agent_signaled = $CHILD_STATUS.signaled?
  LOG.info "#{ctx[:agent_cli]} finished (pid: #{ctx[:pid]}, exit: #{agent_exit_status})"

  if ctx[:source] && agent_exit_status && agent_exit_status != 0 && !agent_signaled
    notify_agent_crash(
      exit_status: agent_exit_status, log_file: ctx[:log_file],
      agent_name: ctx[:agent_name], source: ctx[:source], source_context: ctx[:source_context],
      project_config: ctx[:project_config]
    )
  end

  # Emit lifecycle hook — plugins handle post-session actions (e.g., plugin moves card, appends footer)
  Brainiac.emit(:agent_completed,
                card_number: ctx[:card_number] || ctx[:source_context]&.dig(:card_number),
                exit_status: agent_exit_status,
                signaled: agent_signaled,
                agent_name: ctx[:agent_name],
                chdir: ctx[:chdir],
                source: ctx[:source],
                source_context: ctx[:source_context],
                project_config: ctx[:project_config],
                skip_column_move: ctx[:skip_column_move],
                prompt_file: ctx[:prompt_file])

  qmd_out, qmd_status = Open3.capture2e("qmd", "update")
  if qmd_status.success?
    LOG.info "[Brain] qmd update completed after #{ctx[:agent_config_name] || "agent"} session"
  else
    LOG.warn "[Brain] qmd update failed: #{qmd_out.strip}"
  end

  skill_candidate = detect_skill_candidate(ctx[:log_file])
  if skill_candidate[:extract]
    LOG.info "[Skills] Session qualifies for skill extraction " \
             "(#{skill_candidate[:tool_calls]} tool calls, #{skill_candidate[:error_patterns]} error patterns) " \
             "— agent was nudged via reflection prompt"
  end

  brain_push(message: "#{ctx[:agent_config_name] || "agent"}: #{ctx[:log_name]}")
  # check_brainiac_restart(ctx[:head_before], ctx[:status_before], ctx[:chdir], ctx[:project_key_for_restart], ctx[:agent_config_name])
end

def check_brainiac_restart(head_before, status_before, chdir, project_key_for_restart, agent_config_name)
  return unless project_key_for_restart == "brainiac" && head_before

  head_after, status_after = capture_git_state(chdir)
  if head_after != head_before || status_after != (status_before || "")
    queue_brainiac_restart(agent_config_name || "agent")
  else
    LOG.info "[Brainiac] #{agent_config_name || "agent"} session on brainiac had no changes — skipping restart"
  end
end

def detect_model(project_config, tags: [], text: "")
  resolved = resolve_project_cli_config(project_config)
  allowed_models = resolved["allowed_models"] || {}
  return resolved["agent_model"] if allowed_models.empty?

  if (match = text.match(/\[(\w+)\]/))
    key = match[1].downcase
    return allowed_models[key] if allowed_models.key?(key)
  end

  tags.each do |tag|
    key = (tag.is_a?(Hash) ? tag["name"] : tag).to_s.downcase
    return allowed_models[key] if allowed_models.key?(key)
  end

  resolved["agent_model"]
end

# Detect effort level from inline tags [effort:high] or card tags (effort-high).
# Returns the effort level string (e.g. "high") or nil.
# If the requested level isn't supported by the current model, returns the closest
# lower level from allowed_efforts.
def detect_effort(project_config, tags: [], text: "")
  resolved = resolve_project_cli_config(project_config)
  allowed = resolved["allowed_efforts"] || %w[low medium high xhigh max]

  # Inline tag: [effort:high] — works in any channel
  if (match = text.match(/\[effort:(\w+)\]/i))
    level = match[1].downcase
    return resolve_effort_level(level, allowed) if allowed.include?(level)
  end

  # Plugin hook: let plugins detect from their own metadata (e.g., card tags)
  results = Brainiac.emit(:detect_effort, tags: tags, allowed: allowed)
  plugin_result = results.compact.first
  return resolve_effort_level(plugin_result, allowed) if plugin_result

  resolved["agent_effort"]
end

# If a level isn't in allowed_efforts, return the closest lower level.
def resolve_effort_level(level, allowed)
  all_levels = %w[low medium high xhigh max]
  return level if allowed.include?(level)

  idx = all_levels.index(level)
  return nil unless idx

  # Walk down to find closest supported lower level
  idx.downto(0) { |i| return all_levels[i] if allowed.include?(all_levels[i]) }
  nil
end

def notify_unauthorized(action, creator_name, card_info)
  msg = "Unauthorized: #{creator_name} triggered #{action} on #{card_info}"
  LOG.warn msg
  system("#{NOTIFICATION_COMMAND} '#{msg}'") if NOTIFICATION_COMMAND
end

# frozen_string_literal: true

# Admin and data API routes.
#
# These are read-only (mostly) endpoints for inspecting system state:
# projects, agents, users, brain, skills, sessions, logs, etc.

# --- Session Helpers ---

def reap_dead_sessions
  ACTIVE_SESSIONS.delete_if do |card_key, info|
    Process.kill(0, info[:pid])
    false
  rescue Errno::ESRCH, Errno::EPERM
    archive_session(card_key, info)
    true
  end
end

def format_active_sessions
  ACTIVE_SESSIONS.map do |card_key, info|
    agent_name = resolve_session_agent_name(card_key, info)
    {
      card_key: card_key, agent: agent_name, pid: info[:pid],
      started_at: info[:started_at].iso8601,
      elapsed_seconds: (Time.now - info[:started_at]).to_i,
      log_file: info[:log_file], alive: true,
      children: child_processes_for(info[:pid])
    }
  end
end

def resolve_session_agent_name(_card_key, info)
  return info[:agent_name] if info[:agent_name]

  agent_display_name("Unknown")
end

def format_recent_sessions
  RECENT_SESSIONS.map do |s|
    {
      card_key: s[:card_key], agent: s[:agent_name] || "Unknown",
      log_file: s[:log_file], started_at: s[:started_at]&.iso8601,
      finished_at: s[:finished_at]&.iso8601
    }
  end
end

def kill_child_process(target_pid)
  Process.kill("TERM", target_pid)
  Thread.new do
    sleep 3
    begin
      Process.kill(0, target_pid)
      Process.kill("KILL", target_pid)
    rescue Errno::ESRCH, Errno::EPERM # rubocop:disable Lint/SuppressedException
    end
  end
  LOG.info "Killed child process #{target_pid} (SIGTERM)"
  { killed: target_pid }.to_json
rescue Errno::ESRCH
  halt 404, { error: "process not found" }.to_json
rescue Errno::EPERM
  halt 403, { error: "permission denied" }.to_json
end

# --- Projects ---

get "/api/projects" do
  content_type :json
  reload_projects!
  { projects: PROJECTS }.to_json
end

get "/api/projects/:key" do
  content_type :json
  reload_projects!
  project_key = params["key"]
  if PROJECTS.key?(project_key)
    { project: PROJECTS[project_key] }.to_json
  else
    halt 404, { error: "Project not found" }.to_json
  end
end

post "/api/reload" do
  content_type :json
  reload_projects!(force: true)
  reload_agent_registry!(force: true)
  reload_user_registry!(force: true)
  ReloadHooks.run_all!
  { status: "reloaded", projects: PROJECTS.keys, agents: all_agent_names.to_a, registry: AGENT_REGISTRY.keys,
    users: USER_REGISTRY["users"].size }.to_json
end

# --- Agents & Roles ---

get "/api/agents" do
  content_type :json
  { default: AI_AGENT_NAME, agents: discover_kiro_agents, all_known: all_agent_names.to_a, roster: agent_roster }.to_json
end

get "/api/roles" do
  content_type :json
  roles = []
  if Dir.exist?(ROLES_DIR)
    Dir.glob(File.join(ROLES_DIR, "*.md")).each do |f|
      name = File.basename(f, ".md")
      agents = AGENT_REGISTRY.select { |_, e| e.is_a?(Hash) && Array(e["role"]).include?(name) }.map { |k, _e| agent_display_name(k) }
      roles << { name: name, agents: agents }
    end
  end
  { roles: roles, dir: ROLES_DIR }.to_json
end

# --- Users ---

get "/api/users" do
  content_type :json
  reload_user_registry!

  filter = params["filter"]
  users = case filter
          when "humans" then human_users
          when "agents" then ai_agents
          else USER_REGISTRY["users"]
          end

  { users: users, total: USER_REGISTRY["users"].size, schema_version: USER_REGISTRY["schema_version"] }.to_json
end

get "/api/users/:identifier" do
  content_type :json
  reload_user_registry!

  identifier = params["identifier"]
  user = find_user(identifier)

  if user
    { user: user }.to_json
  else
    halt 404, { error: "User not found", identifier: identifier }.to_json
  end
end

# --- Brain ---

get "/api/brain" do
  content_type :json
  agent = params["agent"] || AI_AGENT_NAME
  persona_dir = persona_dir_for(agent)
  persona_col = persona_collection_for(agent)

  knowledge_files = File.directory?(KNOWLEDGE_DIR) ? Dir.glob(File.join(KNOWLEDGE_DIR, "**", "*.md")).map { |f| f.sub("#{KNOWLEDGE_DIR}/", "") } : []
  persona_files = File.directory?(persona_dir) ? Dir.glob(File.join(persona_dir, "**", "*.md")).map { |f| f.sub("#{persona_dir}/", "") } : []

  {
    agent: agent,
    knowledge: { dir: KNOWLEDGE_DIR, collection: KNOWLEDGE_COLLECTION, files: knowledge_files },
    persona: { dir: persona_dir, collection: persona_col, files: persona_files }
  }.to_json
end

get "/api/brain/search" do
  content_type :json
  query = params["q"]
  halt 400, { error: "Missing query parameter ?q=" }.to_json unless query && !query.empty?

  agent = params["agent"] || AI_AGENT_NAME
  scope = (params["scope"] || "knowledge").to_sym
  scope = :knowledge unless %i[knowledge persona].include?(scope)
  results = query_brain(query, agent_name: agent, scope: scope, max_results: (params["n"] || 5).to_i)

  { agent: agent, scope: scope, query: query, results: results }.to_json
end

# --- Skills ---

get "/api/skills" do
  content_type :json
  skills = build_skill_index
  { total: skills.size, skills: skills }.to_json
end

post "/api/skills/curate" do
  content_type :json
  result = curate_skills
  result.to_json
end

# --- Dispatch Depth ---

get "/api/dispatch-depth" do
  content_type :json
  {
    max_depth: AGENT_DISPATCH_MAX_DEPTH,
    window_seconds: AGENT_DISPATCH_WINDOW,
    cards: AGENT_DISPATCH_DEPTH.transform_values do |v|
      { count: v[:count], last_human_at: v[:last_human_at]&.iso8601, blocked: v[:count] >= AGENT_DISPATCH_MAX_DEPTH }
    end
  }.to_json
end

# --- Sessions ---

get "/api/status" do
  content_type :json
  ACTIVE_SESSIONS_MUTEX.synchronize do
    reap_dead_sessions

    sessions = format_active_sessions
    recent = format_recent_sessions

    { sessions: sessions, count: sessions.size, recent: recent, version: BRAINIAC_VERSION,
      server_root: File.expand_path("../../..", __dir__) }.to_json
  end
end

post "/api/sessions/kill/:card_key" do
  content_type :json
  card_key = params[:card_key]
  halt 400, { error: "missing card_key" }.to_json if card_key.to_s.empty?

  killed = kill_session(card_key)
  halt 404, { error: "session not found" }.to_json unless killed

  LOG.info "Killed agent session #{card_key} via API"
  { killed: card_key }.to_json
end

post "/api/sessions/kill-process/:pid" do
  content_type :json
  target_pid = params[:pid].to_i
  halt 400, { error: "invalid pid" }.to_json if target_pid <= 0

  valid = ACTIVE_SESSIONS_MUTEX.synchronize do
    ACTIVE_SESSIONS.any? do |_, info|
      child_processes_for(info[:pid]).any? { |c| c[:pid] == target_pid }
    end
  end
  halt 403, { error: "pid is not a child of any active agent session" }.to_json unless valid

  kill_child_process(target_pid)
end

# --- Logs ---

get "/api/logs" do
  content_type "text/plain"
  log_file = params["file"]
  lines = (params["lines"] || 200).to_i

  halt 400, "Missing ?file= parameter" unless log_file && !log_file.empty?
  halt 400, "Invalid path" if log_file.include?("..") || !log_file.start_with?("/")
  halt 404, "File not found" unless File.exist?(log_file)

  allowed = PROJECTS.values.map { |p| File.join(p["repo_path"], "tmp") }
  allowed << File.join(BRAINIAC_DIR, "tmp")
  halt 403, "Forbidden" unless allowed.any? { |dir| log_file.start_with?(dir) }

  all_lines = File.readlines(log_file).last(lines)
  all_lines.join.gsub(/\e\[[\d;]*[a-zA-Z]/, "").gsub(/\e\[\?[\d;]*[a-zA-Z]/, "")
end

# --- Cron ---

get "/api/cron/script" do
  content_type "text/plain"
  path = params["path"]
  halt 400, "Missing ?path= parameter" unless path && !path.empty?
  halt 400, "Invalid path" if path.include?("..")

  valid = CRON_JOBS.values.any? do |j|
    j[:script] == path || j["script"] == path ||
      (j[:prompt] || j["prompt"] || "").include?(path)
  end
  halt 403, "Not a registered cron script" unless valid
  halt 404, "File not found" unless File.exist?(path)

  File.read(path)
end

get "/api/cron" do
  content_type :json
  reload_cron_jobs!
  {
    enabled: true,
    jobs: CRON_JOBS,
    thread_alive: CRON_THREAD[:ref]&.alive? || false
  }.to_json
end

post "/api/cron/add" do
  content_type :json
  request.body.rewind
  payload = JSON.parse(request.body.read)

  result = add_cron_job(
    id: payload["id"],
    schedule: payload["schedule"],
    agent: payload["agent"],
    project: payload["project"],
    prompt: payload["prompt"],
    script: payload["script"],
    model: payload["model"],
    effort: payload["effort"],
    notify_channel: payload["notify_channel"],
    notify_target: payload["notify_target"],
    forum_title: payload["forum_title"],
    forum_reply_to_latest: payload["forum_reply_to_latest"] || false,
    repeat_count: payload["repeat_count"]
  )

  result.to_json
end

post "/api/cron/remove" do
  content_type :json
  request.body.rewind
  payload = JSON.parse(request.body.read)

  result = remove_cron_job(payload["id"])
  result.to_json
end

post "/api/cron/toggle" do
  content_type :json
  request.body.rewind
  payload = JSON.parse(request.body.read)

  result = toggle_cron_job(payload["id"], payload["enabled"])
  result.to_json
end

post "/api/cron/update" do
  content_type :json
  request.body.rewind
  payload = JSON.parse(request.body.read)

  result = update_cron_job(
    payload["id"],
    schedule: payload["schedule"],
    notify_target: payload["notify_target"],
    notify_channel: payload["notify_channel"],
    forum_title: payload["forum_title"],
    forum_reply_to_latest: payload["forum_reply_to_latest"]
  )
  result.to_json
end

post "/api/cron/reload" do
  content_type :json
  reload_cron_jobs!
  { status: "reloaded", jobs: CRON_JOBS.size }.to_json
end

# --- Intent ---

get "/api/intent/config" do
  content_type :json
  intent_config.to_json
end

post "/api/intent/check" do
  content_type :json
  request.body.rewind
  payload = JSON.parse(request.body.read)

  message = payload["message"]
  agent = payload["agent"] || AI_AGENT_NAME
  channel = payload["channel"] || "conversation"

  halt 400, { error: "Missing 'message' field" }.to_json unless message && !message.empty?

  result = check_intent(message, agent_name: agent, channel: channel)
  { should_respond: result, agent: agent, channel: channel }.to_json
end

# --- Cron Logs ---

get "/api/cron/logs" do
  content_type :json
  job_id = params["id"]
  halt 400, { error: "Missing ?id= parameter" }.to_json unless job_id && !job_id.empty?

  logs = []
  PROJECTS.each_value do |proj|
    tmp_dir = File.join(proj["repo_path"], "tmp")
    next unless Dir.exist?(tmp_dir)

    Dir.glob(File.join(tmp_dir, "{agent-cron,cron-script}-#{job_id}-*.log")).each do |f|
      logs << { file: f, size: File.size(f), modified: File.mtime(f).iso8601 }
    end
  end
  logs.sort_by! { |l| l[:modified] }.reverse!
  logs.first(20).to_json
end

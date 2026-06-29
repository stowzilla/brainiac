# frozen_string_literal: true

# Fizzy card assignment handler.
#
# When a card is assigned to a local agent, creates a worktree, builds the prompt,
# and dispatches the agent to begin work.

def handle_card_assigned(payload)
  eventable = payload["eventable"] || {}
  assignees = eventable["assignees"] || []

  # Check if any LOCAL agent was assigned
  local_names = local_agent_names
  assigned_agent = assignees.map { |a| a["name"] }.find { |name| local_names.include?(name) }

  assignee_names = assignees.map { |a| a["name"] }.join(", ")
  LOG.info "[Fizzy] Card assigned to: [#{assignee_names}], local agents: [#{local_names.join(", ")}]"

  unless assigned_agent
    LOG.info "[Fizzy] No local agent matched. Assignees: [#{assignee_names}], Local: [#{local_names.join(", ")}]"
    return [200, { status: "ignored", reason: "wrong assignee" }.to_json]
  end

  unless authorized?(payload)
    creator_name = payload.dig("creator", "name") || "Unknown"
    notify_unauthorized("card_assigned", creator_name, "card ##{eventable["number"]}")
    return [200, { status: "ignored", reason: "unauthorized" }.to_json]
  end

  card_number = eventable["number"]
  card_internal_id = eventable["id"]
  title = eventable["title"] || "untitled"
  tags = eventable["tags"] || []

  # Identify project by tags
  project_result = identify_project_by_tags(tags)
  unless project_result
    LOG.warn "No project found for card ##{card_number} with tags: #{tags.map { |t| t.is_a?(Hash) ? t["name"] : t }.join(", ")}"
    return [200, { status: "ignored", reason: "no matching project" }.to_json]
  end

  project_key, project_config = project_result
  repo_path = project_config["repo_path"]

  branch = "fizzy-#{card_number}-#{slugify(title)}"
  model = detect_model(project_config, tags: tags)
  effort = detect_effort(project_config, tags: tags)
  cli_provider_override = detect_cli_provider(tags: tags)

  card_key = "card-#{card_number}"
  if session_active?(card_key)
    LOG.info "Skipping card ##{card_number} — agent session already active"
    return [200, { status: "ignored", reason: "session already active" }.to_json]
  end

  LOG.info "Card ##{card_number} assigned to #{assigned_agent} for project '#{project_key}', creating worktree: #{branch} (model: #{model || "default"})"

  # React in background
  Thread.new do
    emoji = "👍"
    run_cmd("fizzy", "reaction", "create", "--card", card_number.to_s, "--content", emoji, chdir: repo_path, env: fizzy_env_for(assigned_agent))
    LOG.info "Added #{emoji} reaction to card ##{card_number} as #{assigned_agent}"
  rescue StandardError => e
    LOG.warn "Could not add reaction to card: #{e.message}"
  end

  # Fetch latest from origin
  debounced_repo_fetch(repo_path)

  # Create worktree
  worktree_path = File.join(File.dirname(repo_path), "#{File.basename(repo_path)}--#{branch}")
  worktree_path = create_or_reuse_worktree(repo_path: repo_path, branch: branch, worktree_path: worktree_path)

  map = load_card_map
  map[card_internal_id] = {
    "number" => card_number,
    "branch" => branch,
    "worktree" => worktree_path,
    "project" => project_key,
    "agent" => assigned_agent
  }
  save_card_map(map)

  agent_name = assigned_agent
  card_context = prefetch_card_context(card_number, repo_path: repo_path, agent_name: agent_name)

  # Detect planning mode
  planning_info = detect_planning_mode(
    text: title,
    tags: tags,
    card_internal_id: card_internal_id,
    card_number: card_number
  )

  prompt = if planning_info
             card_id = planning_info[:card_id]
             LOG.info "[Planning] Planning mode active for card ##{card_number}"

             render_planning_prompt(PROMPT_CARD_ASSIGNED,
                                    { "CARD_NUMBER" => card_number,
                                      "CARD_TITLE" => title,
                                      "BRANCH" => branch,
                                      "CARD_ID" => card_id,
                                      "COMMENT_CREATOR" => assigned_agent },
                                    brain_context: build_brain_context(agent_name: agent_name, card_title: title, card_number: card_number, project_key: project_key,
                                                                       source: :fizzy),
                                    card_context: card_context,
                                    agent_name: agent_name)
           else
             render_prompt(PROMPT_CARD_ASSIGNED,
                           { "CARD_NUMBER" => card_number,
                             "CARD_TITLE" => title,
                             "BRANCH" => branch,
                             "CARD_ID" => card_number,
                             "COMMENT_CREATOR" => assigned_agent },
                           brain_context: build_brain_context(agent_name: agent_name, card_title: title, card_number: card_number, project_key: project_key,
                                                              source: :fizzy),
                           card_context: card_context,
                           agent_name: agent_name)
           end

  pid, log_file = run_agent(prompt, project_config: project_config, chdir: worktree_path, log_name: "assigned-#{card_number}", model: model, effort: effort, agent_name: agent_name,
                                    card_number: card_number, source: :fizzy, source_context: { card_number: card_number }, cli_provider: cli_provider_override)
  register_session(card_key, pid, log_file: log_file, supersede_key: card_key, agent_name: assigned_agent)

  # Move card to Right Now
  Thread.new { move_card_to_column(card_number, "right_now", project_config: project_config, agent_name: assigned_agent) }

  [200, { status: "processed", card: card_number, branch: branch, project: project_key, agent: assigned_agent }.to_json]
end

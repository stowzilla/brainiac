# frozen_string_literal: true

# GitHub webhook handlers: PR merges, reviews, and issue comments.

# Fallback column ID for backwards compatibility when no board config exists
DEFAULT_UAT_COLUMN_ID = "03fsmglsr6az06ppyotawsti8"

def uat_column_id(project_config)
  bk = board_key_for_project(project_config)
  (bk && board_column_id(bk, "uat")) || DEFAULT_UAT_COLUMN_ID
end

# Find a Fizzy card by matching the PR's head branch to a branch in the card map.
def find_card_by_branch(branch)
  map = load_card_map
  map.each do |internal_id, info|
    next unless info["branch"] == branch

    return [internal_id, info]
  end
  nil
end

# Track a newly opened PR in the card map by matching its branch.
def track_pr_in_card_map(payload)
  pr = payload["pull_request"]
  branch = pr.dig("head", "ref")
  pr_number = pr["number"]
  pr_url = pr["html_url"]

  result = find_card_by_branch(branch)
  unless result
    LOG.info "[PR Track] No card found for branch #{branch}"
    return
  end

  internal_id, card_info = result
  prs = card_info["prs"] || []
  return if prs.any? { |p| p["number"] == pr_number }

  prs << { "number" => pr_number, "url" => pr_url }
  card_info["prs"] = prs

  map = load_card_map
  map[internal_id] = card_info
  save_card_map(map)
  LOG.info "[PR Track] Tracked PR ##{pr_number} on card ##{card_info["number"]} (branch: #{branch})"
end

# Fetch review comments from a PR using GitHub CLI
def fetch_pr_review_comments(pr_number, repo)
  output = run_cmd("gh", "api", "/repos/#{repo}/pulls/#{pr_number}/comments", "--jq", ".[] | {path, line, body, user: .user.login}")
  output.lines.map { |line| JSON.parse(line) }
rescue StandardError => e
  LOG.warn "Could not fetch PR review comments: #{e.message}"
  []
end

# Check if a PR link is already present in the card's comments.
def pr_link_already_commented?(card_number, pr_url, chdir:, env: default_fizzy_env)
  output = run_cmd("fizzy", "comment", "list", "--card", card_number.to_s, chdir: chdir, env: env)
  data = JSON.parse(output)
  comments = data["data"] || []
  comments.any? { |c| (c.dig("body", "plain_text") || "").include?(pr_url) }
rescue StandardError => e
  LOG.warn "Could not check existing comments for card ##{card_number}: #{e.message}"
  false
end

def handle_github_pr_merged(payload)
  pr = payload["pull_request"]
  branch = pr.dig("head", "ref")
  base = pr.dig("base", "ref")
  pr_url = pr["html_url"]
  pr_title = pr["title"]
  repo_full_name = payload.dig("repository", "full_name")

  default_branch = payload.dig("repository", "default_branch") || "main"
  unless base == default_branch
    LOG.info "PR merged into #{base}, not #{default_branch} — ignoring"
    return [200, { status: "ignored", reason: "not merged into #{default_branch}" }.to_json]
  end

  project_result = identify_project_by_repo(repo_full_name)
  unless project_result
    LOG.info "No project found for GitHub repo #{repo_full_name}"
    return [200, { status: "ignored", reason: "no matching project" }.to_json]
  end

  project_key, project_config = project_result
  repo_path = project_config["repo_path"]

  result = find_card_by_branch(branch)
  unless result
    LOG.info "No Fizzy card found for branch #{branch}"
    return [200, { status: "ignored", reason: "no matching card" }.to_json]
  end

  internal_id, card_info = result
  card_number = card_info["number"]
  unless card_number
    LOG.warn "Card #{internal_id} has no number — can't comment or move"
    return [200, { status: "ignored", reason: "card has no number" }.to_json]
  end

  LOG.info "PR merged into main for card ##{card_number} (project: #{project_key}): #{pr_url}"
  process_merged_pr(card_info, card_number, branch, pr, pr_url, pr_title, project_key, project_config, repo_path)

  [200, { status: "processed", card: card_number, pr: pr_url, action: "merged_to_uat", project: project_key }.to_json]
rescue StandardError => e
  LOG.error "Error handling merged PR: #{e.message}"
  [500, { error: e.message }.to_json]
end

def process_merged_pr(card_info, card_number, branch, pull_request, pr_url, pr_title, project_key, project_config, repo_path)
  card_agent = card_info["agent"]
  card_fizzy_env = fizzy_env_for(card_agent)

  unless pr_link_already_commented?(card_number, pr_url, chdir: repo_path, env: card_fizzy_env)
    comment_body = "<p>PR merged into main: <a href=\"#{pr_url}\">#{pr_title}</a></p><p>Branch: <code>#{branch}</code></p>"
    run_cmd("fizzy", "comment", "create", "--card", card_number.to_s, "--body", comment_body, chdir: repo_path, env: card_fizzy_env)
  end

  mark_card_merged(card_number)
  run_cmd("fizzy", "card", "column", card_number.to_s, "--column", uat_column_id(project_config), chdir: repo_path, env: card_fizzy_env)
  record_self_move(card_number)
  cleanup_card_worktrees(card_number, repo_path: repo_path, primary_worktree: card_info["worktree"], primary_branch: branch)
  clear_deployment_for_card(card_number)

  agent_name = card_agent || agent_name_for(project_config)
  card_title = card_info["title"] || pr_title
  dispatch_uat_agent(card_number, card_title, pull_request["number"].to_s, agent_name, project_key, project_config, repo_path)
end

def dispatch_uat_agent(card_number, card_title, pr_number, agent_name, project_key, project_config, repo_path)
  prompt = render_prompt(PROMPT_GITHUB_UAT,
                         { "CARD_NUMBER" => card_number, "CARD_TITLE" => card_title, "PR_NUMBER" => pr_number },
                         brain_context: build_brain_context(agent_name: agent_name, card_number: card_number,
                                                            card_title: card_title, project_key: project_key),
                         agent_name: agent_name, channel: :fizzy,
                         board_key: board_key_for_project(project_config))

  pid, log_file = run_agent(prompt, project_config: project_config, chdir: repo_path,
                                    log_name: "uat-#{card_number}", agent_name: agent_name,
                                    source: :fizzy, source_context: { card_number: card_number }, skip_column_move: true)
  register_session("card-#{card_number}", pid, log_file: log_file, agent_name: agent_name)
  LOG.info "Dispatched #{agent_name} for UAT testing steps on card ##{card_number}"
end

def handle_github_issue_comment(payload)
  comment = payload["comment"]
  issue = payload["issue"]
  comment_body = comment["body"] || ""
  comment_id = comment["id"]
  comment_user = comment.dig("user", "login")
  repo_name = payload.dig("repository", "full_name")

  unless issue["pull_request"]
    LOG.info "Issue comment on non-PR issue ##{issue["number"]}, ignoring"
    return [200, { status: "ignored", reason: "not a PR comment" }.to_json]
  end

  project_result = identify_project_by_repo(repo_name)
  unless project_result
    LOG.info "No project found for GitHub repo #{repo_name}"
    return [200, { status: "ignored", reason: "no matching project" }.to_json]
  end

  project_key, project_config = project_result
  pr_number = issue["number"]

  pr_data = run_cmd("gh", "api", "/repos/#{repo_name}/pulls/#{pr_number}", "--jq", "{branch: .head.ref}",
                    chdir: project_config["repo_path"])
  branch = JSON.parse(pr_data)["branch"]

  result = find_card_by_branch(branch)
  unless result
    LOG.info "No Fizzy card found for PR ##{pr_number} (branch: #{branch})"
    return [200, { status: "ignored", reason: "no matching card" }.to_json]
  end

  _, card_info = result
  card_number = card_info["number"]
  worktree = card_info["worktree"]

  unless worktree && File.directory?(worktree)
    LOG.info "No active worktree for PR ##{pr_number}, ignoring comment"
    return [200, { status: "ignored", reason: "no active worktree" }.to_json]
  end

  card_key = "card-#{card_number}"
  if session_active?(card_key)
    LOG.info "Skipping PR comment on card ##{card_number} — agent session already active"
    return [200, { status: "ignored", reason: "session already active" }.to_json]
  end

  LOG.info "PR comment from #{comment_user} on PR ##{pr_number} for card ##{card_number} (project: #{project_key})"
  dispatch_pr_comment(card_number, card_key, pr_number, comment_id, comment_user, comment_body,
                      repo_name, worktree, project_key, project_config)

  [200, { status: "processed", card: card_number, pr: pr_number, comment_id: comment_id, project: project_key }.to_json]
rescue StandardError => e
  LOG.error "Error handling PR comment: #{e.message}"
  [500, { error: e.message }.to_json]
end

def dispatch_pr_comment(card_number, card_key, pr_number, comment_id, comment_user, comment_body,
                        repo_name, worktree, project_key, project_config)
  Thread.new do
    run_cmd("gh", "api", "-X", "POST", "/repos/#{repo_name}/issues/comments/#{comment_id}/reactions",
            "-f", "content=eyes", "-H", "Accept: application/vnd.github+json", chdir: worktree)
  rescue StandardError => e
    LOG.warn "Could not add reaction to comment: #{e.message}"
  end

  agent_name = agent_name_for(project_config)
  prompt = render_prompt(PROMPT_GITHUB_PR_COMMENT,
                         { "CARD_NUMBER" => card_number, "CARD_ID" => card_number,
                           "COMMENT_CREATOR" => comment_user, "COMMENT_BODY" => comment_body,
                           "PR_NUMBER" => pr_number.to_s, "WORKTREE_PATH" => worktree },
                         brain_context: build_brain_context(agent_name: agent_name, card_number: card_number,
                                                            project_key: project_key, comment_body: comment_body),
                         agent_name: agent_name, channel: :github)

  pid, log_file = run_agent(prompt, project_config: project_config, chdir: worktree,
                                    log_name: "pr-comment-#{pr_number}",
                                    model: detect_model(project_config, text: comment_body),
                                    effort: detect_effort(project_config, text: comment_body),
                                    agent_name: agent_name, source: :github,
                                    source_context: { pr_number: pr_number, repo_name: repo_name, work_dir: worktree })
  register_session(card_key, pid, log_file: log_file, agent_name: agent_name)
end

def handle_github_workflow_run(payload)
  workflow = payload["workflow_run"]
  workflow_name = workflow["name"]
  conclusion = workflow["conclusion"]
  repo_full_name = payload.dig("repository", "full_name")
  run_url = workflow["html_url"]

  if workflow_name == "Deploy to Production" && conclusion == "failure"
    project_key = identify_project_by_repo(repo_full_name)&.first || repo_full_name
    send_workflow_failure_notification(project_key, workflow_name, run_url)
    return [200, { status: "processed", action: "prod_deploy_failure_notified", project: project_key }.to_json]
  end

  if workflow_name == "Deploy to UAT" && conclusion == "success"
    project_key = identify_project_by_repo(repo_full_name)&.first || repo_full_name
    send_uat_deploy_notification(project_key)
    return [200, { status: "processed", action: "uat_deploy_notified", project: project_key }.to_json]
  end

  return [200, { status: "ignored", reason: "conclusion: #{conclusion}" }.to_json] unless conclusion == "success"

  return [200, { status: "ignored", reason: "workflow: #{workflow_name}" }.to_json] unless workflow_name == "Deploy to Production"

  project_result = identify_project_by_repo(repo_full_name)
  return [200, { status: "ignored", reason: "no matching project" }.to_json] unless project_result

  project_key, project_config = project_result
  close_uat_cards_after_deploy(project_key, project_config)
rescue StandardError => e
  LOG.error "Error handling workflow run: #{e.message}"
  [500, { error: e.message }.to_json]
end

def close_uat_cards_after_deploy(project_key, project_config)
  repo_path = project_config["repo_path"]
  output = run_cmd("fizzy", "card", "list", "--column", uat_column_id(project_config), "--all",
                   chdir: repo_path, env: default_fizzy_env)
  card_list = JSON.parse(output)["data"] || []

  if card_list.empty?
    LOG.info "No cards in UAT column — nothing to close"
    return [200, { status: "processed", action: "no_uat_cards", project: project_key }.to_json]
  end

  closed_cards = close_and_cleanup_uat_cards(card_list, repo_path)
  send_deploy_notification(project_key, closed_cards) if closed_cards.any?

  LOG.info "Prod deploy complete — closed #{closed_cards.size} UAT cards: #{closed_cards.map { |c| c[:number] }.join(", ")}"
  [200, { status: "processed", action: "prod_deploy_closed_uat",
          closed_cards: closed_cards.map { |c| c[:number] }, project: project_key }.to_json]
end

def close_and_cleanup_uat_cards(card_list, repo_path)
  closed_cards = []
  map = load_card_map

  card_list.each do |card|
    card_number = card["number"]
    next unless card_number

    map_entry = map.values.find { |info| info["number"] == card_number }
    agent_name = map_entry["agent"] if map_entry
    env = agent_name ? fizzy_env_for(agent_name) : default_fizzy_env

    run_cmd("fizzy", "comment", "create", "--card", card_number.to_s,
            "--body", "<p>✅ Deployed to production. Closing card.</p>", chdir: repo_path, env: env)
    run_cmd("fizzy", "card", "close", card_number.to_s, chdir: repo_path, env: env)

    cleanup_card_worktrees(card_number, repo_path: repo_path,
                                        primary_worktree: map_entry&.dig("worktree"), primary_branch: map_entry&.dig("branch"))

    if map_entry
      internal_id = map.key(map_entry)
      map.delete(internal_id)
    end

    closed_cards << { number: card_number, url: card["url"], title: card["title"] }
    LOG.info "Closed UAT card ##{card_number} after prod deploy (agent: #{agent_name || "default"})"
  end

  save_card_map(map) if closed_cards.any?
  closed_cards
end

def send_deploy_notification(project_key, closed_cards)
  channel_id = DISCORD_CONFIG["deploy_notification_channel_id"]
  return unless channel_id

  token = discord_bot_tokens.values.first
  return unless token

  card_lines = closed_cards.map { |c| "• [##{c[:number]} — #{c[:title]}](#{c[:url]})" }.join("\n")
  message = "🚀 **#{project_key.capitalize}** deployed to production\nClosed UAT cards:\n#{card_lines}"

  send_discord_message(channel_id, message, token: token)
rescue StandardError => e
  LOG.warn "Failed to send deploy notification: #{e.message}"
end

def send_uat_deploy_notification(project_key)
  channel_id = DISCORD_CONFIG["deploy_notification_channel_id"]
  return unless channel_id

  token = discord_bot_tokens.values.first
  return unless token

  message = "✅ **#{project_key.capitalize}** deployed to UAT successfully"
  send_discord_message(channel_id, message, token: token)
rescue StandardError => e
  LOG.warn "Failed to send UAT deploy notification: #{e.message}"
end

def send_workflow_failure_notification(project_key, workflow_name, run_url)
  channel_id = DISCORD_CONFIG["deploy_notification_channel_id"]
  return unless channel_id

  token = discord_bot_tokens.values.first
  return unless token

  message = "❌ **#{project_key.capitalize}** — #{workflow_name} failed\n[View run](#{run_url})"
  send_discord_message(channel_id, message, token: token)
rescue StandardError => e
  LOG.warn "Failed to send workflow failure notification: #{e.message}"
end

def handle_github_issue_opened(payload)
  issue = payload["issue"]
  issue_url = issue["html_url"]
  issue_title = issue["title"]
  issue_number = issue["number"]
  repo_name = payload.dig("repository", "full_name")

  LOG.info "New GitHub issue ##{issue_number} on #{repo_name}: #{issue_title} (#{issue_url})"

  [200, { status: "logged", issue: issue_number, title: issue_title, url: issue_url }.to_json]
end

def handle_github_pr_review_submitted(payload)
  pr = payload["pull_request"]
  review = payload["review"]
  branch = pr.dig("head", "ref")
  pr_number = pr["number"]
  repo_name = payload.dig("repository", "full_name")
  review_state = review["state"]
  reviewer = review.dig("user", "login")

  return [200, { status: "ignored", reason: "review state: #{review_state}" }.to_json] unless %w[changes_requested commented].include?(review_state)

  project_result = identify_project_by_repo(repo_name)
  return [200, { status: "ignored", reason: "no matching project" }.to_json] unless project_result

  project_key, project_config = project_result
  repo_path = project_config["repo_path"]

  result = find_card_by_branch(branch)
  return [200, { status: "ignored", reason: "no matching card" }.to_json] unless result

  internal_id, card_info = result
  card_number = card_info["number"]
  unless card_number
    LOG.warn "Card #{internal_id} has no number — can't comment"
    return [200, { status: "ignored", reason: "card has no number" }.to_json]
  end

  card_key = "card-#{card_number}"
  return [200, { status: "ignored", reason: "session already active" }.to_json] if session_active?(card_key)

  LOG.info "PR review submitted by #{reviewer} on PR ##{pr_number} for card ##{card_number} (project: #{project_key})"
  dispatch_pr_review(card_number, card_key, card_info, pr_number, review, reviewer, repo_name, project_key, project_config, repo_path)

  [200, { status: "processed", card: card_number, pr: pr_number, reviewer: reviewer, project: project_key }.to_json]
rescue StandardError => e
  LOG.error "Error handling PR review: #{e.message}"
  [500, { error: e.message }.to_json]
end

def dispatch_pr_review(card_number, card_key, card_info, pr_number, review, reviewer, repo_name, project_key, project_config, repo_path)
  review_id = review["id"]
  Thread.new do
    run_cmd("gh", "api", "-X", "POST", "/repos/#{repo_name}/pulls/reviews/#{review_id}/reactions",
            "-f", "content=eyes", "-H", "Accept: application/vnd.github+json", chdir: repo_path)
  rescue StandardError => e
    LOG.warn "Could not add reaction to review: #{e.message}"
  end

  agent_name = agent_name_for(project_config)
  Thread.new do
    status_comment = "<p>🔄 Code review received from @#{reviewer}. Updates in progress...</p>"
    run_cmd("fizzy", "comment", "create", "--card", card_number.to_s, "--body", status_comment,
            chdir: repo_path, env: fizzy_env_for(agent_name))
  rescue StandardError => e
    LOG.warn "Could not post status update to card ##{card_number}: #{e.message}"
  end

  review_context = build_review_context(reviewer, review, pr_number, repo_name)
  worktree = card_info["worktree"]
  work_dir = worktree && File.directory?(worktree) ? worktree : repo_path

  prompt = render_prompt(PROMPT_GITHUB_PR_REVIEW,
                         { "CARD_NUMBER" => card_number, "CARD_ID" => card_number,
                           "COMMENT_CREATOR" => reviewer, "REVIEW_CONTEXT" => review_context,
                           "PR_NUMBER" => pr_number.to_s, "WORKTREE_PATH" => work_dir },
                         brain_context: build_brain_context(agent_name: agent_name, card_number: card_number,
                                                            project_key: project_key),
                         agent_name: agent_name, channel: :github)

  pid, log_file = run_agent(prompt, project_config: project_config, chdir: work_dir,
                                    log_name: "review-#{card_number}", agent_name: agent_name,
                                    source: :github,
                                    source_context: { pr_number: pr_number, repo_name: repo_name, work_dir: work_dir })
  register_session(card_key, pid, log_file: log_file, agent_name: agent_name)
end

def build_review_context(reviewer, review, pr_number, repo_name)
  context = "GitHub PR Review from @#{reviewer}:\n\n"
  context += "Review body:\n#{review["body"]}\n\n" if review["body"] && !review["body"].empty?

  review_comments = fetch_pr_review_comments(pr_number, repo_name)
  if review_comments.any?
    context += "Line-specific comments:\n"
    review_comments.each do |comment|
      context += "- #{comment["path"]}:#{comment["line"]} (@#{comment["user"]}): #{comment["body"]}\n"
    end
  end
  context
end

def handle_github_pr_synchronized(payload)
  pr = payload["pull_request"]
  branch = pr.dig("head", "ref")

  result = find_card_by_branch(branch)
  return [200, { status: "ignored", reason: "no matching card" }.to_json] unless result

  _internal_id, card_info = result
  card_number = card_info["number"]
  worktree = card_info["worktree"]

  return [200, { status: "ignored", reason: "no worktree" }.to_json] unless worktree && File.directory?(worktree)

  state = load_deployment_state
  config = DEPLOYMENTS_CONFIG["environments"] || {}
  env_key = state.find { |_k, v| v["card_number"] == card_number && v["status"] == "occupied" }&.first

  return [200, { status: "ignored", reason: "card not deployed" }.to_json] unless env_key

  env_owner = config.dig(env_key, "owner")
  return [200, { status: "ignored", reason: "not env owner" }.to_json] unless env_owner && env_owner.downcase == AI_AGENT_NAME.downcase

  return [200, { status: "ignored", reason: "deploy cooldown" }.to_json] if on_deploy_cooldown?(env_key)

  touch_deploy_cooldown(env_key)

  system("git", "pull", "--ff-only", chdir: worktree)
  deploy_script = File.join(worktree, "scripts", "deploy.sh")
  return [200, { status: "ignored", reason: "no deploy script" }.to_json] unless File.exist?(deploy_script)

  LOG.info "[PR Sync] Auto-deploying card ##{card_number} to #{env_key} (PR updated)"
  mark_deploying(env_key, worktree_path: worktree)
  run_pr_sync_deploy(env_key, card_number, worktree, config)

  [200, { status: "processed", action: "pr_sync_deploy", card: card_number, env: env_key }.to_json]
rescue StandardError => e
  LOG.error "[PR Sync] Error: #{e.message}"
  [500, { error: e.message }.to_json]
end

def run_pr_sync_deploy(env_key, card_number, worktree, config)
  Thread.new do
    deploy_env = {}
    aws_profile = config.dig(env_key, "aws_profile")
    deploy_env["AWS_PROFILE"] = aws_profile if aws_profile
    deploy_script = File.join(worktree, "scripts", "deploy.sh")

    stdout, stderr, status = Open3.capture3(deploy_env, deploy_script, env_key, chdir: worktree)

    if status.success?
      deploy_to_environment(env_key, worktree_path: worktree, deployed_by: "pr-sync")
      LOG.info "[PR Sync] Deploy to #{env_key} succeeded for card ##{card_number}"
    elsif terraform_lock_error?(stdout, stderr)
      retry_pr_sync_deploy(deploy_env, deploy_script, env_key, card_number, worktree)
    else
      record_deploy_failure(env_key, worktree_path: worktree, stdout: stdout, stderr: stderr)
      LOG.error "[PR Sync] Deploy to #{env_key} failed for card ##{card_number}"
    end
  end
end

def retry_pr_sync_deploy(deploy_env, deploy_script, env_key, card_number, worktree)
  infra_dir = File.join(worktree, "infrastructure/#{env_key}")
  FileUtils.rm_f(File.join(infra_dir, ".terraform.lock.hcl"))
  Open3.capture3("terraform", "init", "-upgrade", chdir: infra_dir)
  stdout, stderr, status = Open3.capture3(deploy_env, deploy_script, env_key, chdir: worktree)

  if status.success?
    deploy_to_environment(env_key, worktree_path: worktree, deployed_by: "pr-sync")
    LOG.info "[PR Sync] Deploy to #{env_key} succeeded (after terraform lock fix) for card ##{card_number}"
  else
    record_deploy_failure(env_key, worktree_path: worktree, stdout: stdout, stderr: stderr)
    LOG.error "[PR Sync] Deploy to #{env_key} failed (after retry) for card ##{card_number}"
  end
end

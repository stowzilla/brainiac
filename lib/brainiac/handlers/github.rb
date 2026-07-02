# frozen_string_literal: true

# GitHub webhook handlers: PR merges, reviews, and issue comments.

# Fallback column ID for backwards compatibility when no board config exists
DEFAULT_UAT_COLUMN_ID = "03fsmglsr6az06ppyotawsti8"


# Find a work item by matching the PR's head branch to a branch in the card map.
def find_work_item_by_branch(branch)
  map = load_work_item_map
  map.each do |internal_id, info|
    next unless info["branch"] == branch

    return [internal_id, info]
  end
  nil
end

# Track a newly opened PR in the work item map by matching its branch.
def track_pr_in_work_items(payload)
  pr = payload["pull_request"]
  branch = pr.dig("head", "ref")
  pr_number = pr["number"]
  pr_url = pr["html_url"]

  result = find_work_item_by_branch(branch)
  unless result
    LOG.info "[PR Track] No card found for branch #{branch}"
    return
  end

  internal_id, card_info = result
  prs = card_info["prs"] || []
  return if prs.any? { |p| p["number"] == pr_number }

  prs << { "number" => pr_number, "url" => pr_url }
  card_info["prs"] = prs

  map = load_work_item_map
  map[internal_id] = card_info
  save_work_item_map(map)
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

  result = find_work_item_by_branch(branch)
  unless result
    LOG.info "No card found for branch #{branch}"
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
  mark_work_item_merged(card_number)
  cleanup_work_item_worktrees(card_number, repo_path: repo_path, primary_worktree: card_info["worktree"], primary_branch: branch)

  # Emit hook — plugins handle their own post-merge actions
  # (e.g., card plugin posts PR link, moves card column, dispatches UAT agent)
  Brainiac.emit(:pr_merged,
                card_number: card_number,
                card_info: card_info,
                branch: branch,
                pull_request: pull_request,
                pr_url: pr_url,
                pr_title: pr_title,
                project_key: project_key,
                project_config: project_config,
                repo_path: repo_path)
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

  result = find_work_item_by_branch(branch)
  unless result
    LOG.info "No card found for PR ##{pr_number} (branch: #{branch})"
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
  # Emit hook — work item plugins handle closing cards after production deploy
  results = Brainiac.emit(:production_deployed, project_key: project_key, project_config: project_config)
  closed_cards = results.flatten.compact

  if closed_cards.any?
    send_deploy_notification(project_key, closed_cards)
    LOG.info "Prod deploy complete — closed #{closed_cards.size} cards"
  else
    LOG.info "Prod deploy processed — no cards closed (plugin may not be installed)"
  end

  [200, { status: "processed", action: "prod_deploy", closed_cards: closed_cards.map { |c| c[:number] }, project: project_key }.to_json]
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

  result = find_work_item_by_branch(branch)
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
  # Notify work item system that a review was received (plugin posts status comment)
  Brainiac.emit(:pr_review_received, card_number: card_number, reviewer: reviewer,
                                      agent_name: agent_name, project_config: project_config, repo_path: repo_path)

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

  result = find_work_item_by_branch(branch)
  return [200, { status: "ignored", reason: "no matching card" }.to_json] unless result

  _internal_id, card_info = result
  card_number = card_info["number"]
  worktree = card_info["worktree"]

  return [200, { status: "ignored", reason: "no worktree" }.to_json] unless worktree && File.directory?(worktree)

  # Emit hook — deployment plugin handles sync-deploy logic
  results = Brainiac.emit(:pr_synchronized, card_number: card_number, card_info: card_info,
                                            worktree: worktree, pull_request: pr, branch: branch)

  if results.any?
    [200, { status: "processed", action: "pr_sync", card: card_number }.to_json]
  else
    [200, { status: "ignored", reason: "no deployment plugin" }.to_json]
  end
rescue StandardError => e
  LOG.error "[PR Sync] Error: #{e.message}"
  [500, { error: e.message }.to_json]
end

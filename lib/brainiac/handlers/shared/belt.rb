# frozen_string_literal: true

# Belt application detection and environment management utilities.
#
# Belt is a Ruby framework for building serverless applications on AWS Lambda.
# Projects using Belt have infrastructure defined in `config/routes.rb` or the
# legacy `infrastructure/routes.tf.rb` path.
#
# This module provides detection and ephemeral environment helpers that plugins
# (brainiac-fizzy, brainiac-github, brainiac-basecamp) can use.

# Module containing Belt-related helpers accessible from Sinatra routes.
module BeltHelpers
  # Detect if a directory is a Belt application by checking for routes file.
  #
  # Belt apps are detected by the presence of any of these files:
  #   - config/routes.rb (current)
  #   - config/routes.tf.rb (legacy)
  #   - infrastructure/routes.tf.rb (legacy)
  #
  # @param path [String] Path to check (repo root or worktree)
  # @return [Boolean] True if the path contains a Belt application
  def belt_app?(path)
    return false unless path && File.directory?(path)

    candidates = [
      File.join(path, "config/routes.rb"),
      File.join(path, "config/routes.tf.rb"),
      File.join(path, "infrastructure/routes.tf.rb")
    ]
    candidates.any? { |f| File.exist?(f) }
  end

  # Check if a Belt app routes file exists and contains actual route definitions.
  # This is a stricter check than belt_app? — it verifies the file has Belt routes,
  # not just a Rails routes.rb file (which wouldn't have Belt-style route definitions).
  #
  # @param path [String] Path to check
  # @return [Boolean] True if the path contains a Belt routes file with Belt syntax
  def belt_routes_file?(path)
    routes_file = belt_routes_path(path)
    return false unless routes_file && File.exist?(routes_file)

    # Check for Belt-specific syntax (e.g., `app.get`, `api`, `resources`, etc.)
    content = File.read(routes_file, 4096) # Read first 4KB
    content.match?(/\bapp\.(get|post|put|patch|delete)\b/) ||
      content.match?(/\bapi\s+do\b/) ||
      content.match?(/\bresources?\s+:/) ||
      content.match?(/\bBelt\.routes\b/)
  rescue StandardError
    false
  end

  # Get the path to the Belt routes file (checking all possible locations).
  #
  # @param path [String] Path to check
  # @return [String, nil] Path to routes file or nil
  def belt_routes_path(path)
    return nil unless path && File.directory?(path)

    candidates = [
      File.join(path, "config/routes.rb"),
      File.join(path, "config/routes.tf.rb"),
      File.join(path, "infrastructure/routes.tf.rb")
    ]
    candidates.find { |f| File.exist?(f) }
  end
end

# Configuration for Belt ephemeral environments.
# Stored in ~/.brainiac/basecamp.json under the "deploy" key.
module BeltConfig
  BRAINIAC_DIR = ENV.fetch("BRAINIAC_DIR", File.join(Dir.home, ".brainiac"))
  BASECAMP_CONFIG_FILE = File.join(BRAINIAC_DIR, "basecamp.json")
  DEPLOYMENTS_CONFIG_FILE = File.join(BRAINIAC_DIR, "deployments.json")

  class << self
    # Load the basecamp config, caching for performance.
    # @return [Hash]
    def load_config
      return {} unless File.exist?(BASECAMP_CONFIG_FILE)

      JSON.parse(File.read(BASECAMP_CONFIG_FILE))
    rescue JSON::ParserError => e
      LOG.error "[Belt] Failed to parse basecamp.json: #{e.message}" if defined?(LOG)
      {}
    end

    # Resolve the AWS profile for an environment from deployments.json.
    #
    # The monitor/status-bar deploy scripts read the same config
    # (`~/.brainiac/deployments.json` → `environments.<env>.aws_profile`) and
    # export AWS_PROFILE before shelling out. Server-side belt commands must do
    # the same so `belt g environment`, `belt deploy`, and `belt destroy` target
    # the correct AWS account instead of falling back to default credentials.
    #
    # @param env_name [String] Environment name (e.g. "fizzy-1299")
    # @return [String, nil] AWS profile name or nil when unconfigured
    def aws_profile_for(env_name)
      return nil unless env_name && File.exist?(DEPLOYMENTS_CONFIG_FILE)

      config = JSON.parse(File.read(DEPLOYMENTS_CONFIG_FILE))
      profile = config.dig("environments", env_name.to_s, "aws_profile")
      profile if profile && !profile.to_s.strip.empty?
    rescue JSON::ParserError => e
      LOG.error "[Belt] Failed to parse deployments.json: #{e.message}" if defined?(LOG)
      nil
    rescue StandardError
      nil
    end

    # Build the environment hash to pass to belt CLI invocations for a given
    # environment. Returns AWS_PROFILE when one is configured, otherwise an empty
    # hash (so the child process inherits the parent environment unchanged).
    #
    # @param env_name [String] Environment name
    # @return [Hash{String=>String}] Env overrides for Open3
    def belt_cli_env(env_name)
      profile = aws_profile_for(env_name)
      return {} unless profile

      LOG.info "[Belt] Using AWS_PROFILE=#{profile} for '#{env_name}'" if defined?(LOG)
      { "AWS_PROFILE" => profile }
    end

    # Get the parent environment for a project (used as base for ephemeral envs).
    # This is where `belt g environment <name> <parent>` copies settings from.
    #
    # @param project_key [String] Brainiac project key
    # @return [String, nil] Parent environment name (e.g., "dev02", "dev") or nil
    def parent_env_for(project_key)
      config = load_config
      config.dig("deploy", "project_envs", project_key)
    end

    # Check if ephemeral deploys are enabled globally.
    # @return [Boolean]
    def ephemeral_deploys_enabled?
      config = load_config
      # Default to true if deploy section exists but enabled isn't specified
      deploy_config = config["deploy"] || {}
      deploy_config.fetch("ephemeral_enabled", true)
    end

    # Track an ephemeral environment in deployment state.
    # @param env_name [String] Environment name (e.g., "fizzy-123")
    # @param metadata [Hash] Metadata about the ephemeral env
    def track_ephemeral_env(env_name, metadata = {})
      state_file = File.join(BRAINIAC_DIR, "ephemeral_envs.json")
      state = File.exist?(state_file) ? JSON.parse(File.read(state_file)) : {}

      state[env_name] = {
        "created_at" => Time.now.iso8601,
        "status" => "active"
      }.merge(metadata)

      File.write(state_file, JSON.pretty_generate(state))
    rescue StandardError => e
      LOG.error "[Belt] Failed to track ephemeral env: #{e.message}" if defined?(LOG)
    end

    # Check if an environment is ephemeral.
    # @param env_name [String] Environment name
    # @return [Boolean]
    def ephemeral_env?(env_name)
      state_file = File.join(BRAINIAC_DIR, "ephemeral_envs.json")
      return false unless File.exist?(state_file)

      state = JSON.parse(File.read(state_file))
      state.key?(env_name) && state[env_name]["status"] == "active"
    rescue StandardError
      false
    end

    # Get ephemeral environment metadata.
    # @param env_name [String] Environment name
    # @return [Hash, nil]
    def ephemeral_env_info(env_name)
      state_file = File.join(BRAINIAC_DIR, "ephemeral_envs.json")
      return nil unless File.exist?(state_file)

      state = JSON.parse(File.read(state_file))
      state[env_name]
    rescue StandardError
      nil
    end

    # Mark an ephemeral environment as destroyed.
    # @param env_name [String] Environment name
    def mark_ephemeral_destroyed(env_name)
      state_file = File.join(BRAINIAC_DIR, "ephemeral_envs.json")
      return unless File.exist?(state_file)

      state = JSON.parse(File.read(state_file))
      return unless state[env_name]

      state[env_name]["status"] = "destroyed"
      state[env_name]["destroyed_at"] = Time.now.iso8601

      File.write(state_file, JSON.pretty_generate(state))
    rescue StandardError => e
      LOG.error "[Belt] Failed to mark ephemeral env destroyed: #{e.message}" if defined?(LOG)
    end

    # Find ephemeral environment by card number.
    # @param card_number [Integer, String] Fizzy card number
    # @return [String, nil] Environment name or nil
    def ephemeral_env_for_card(card_number)
      "fizzy-#{card_number}"
    end

    # Find ephemeral environment by epic number.
    # @param epic_number [Integer, String] Epic number
    # @return [String, nil] Environment name or nil
    def ephemeral_env_for_epic(epic_number)
      "epic-#{epic_number}"
    end
  end
end

# Belt environment operations (create, deploy, destroy).
# These wrap the `belt` CLI commands for ephemeral environment management.
module BeltEnvironment
  class << self
    include BeltHelpers

    # Check whether an environment is configured in a worktree.
    # `belt g environment` writes infrastructure/<env_name>/; that directory
    # is the source of truth, not the ephemeral_envs.json tracking file.
    #
    # @param worktree [String] Path to the worktree
    # @param env_name [String] Environment name (e.g. "fizzy-1299")
    # @return [Boolean]
    def environment_configured?(worktree:, env_name:)
      return false unless worktree && env_name && File.directory?(worktree)

      File.directory?(File.join(worktree, "infrastructure", env_name.to_s))
    end

    # Create an ephemeral environment from a parent environment.
    #
    # @param worktree [String] Path to the worktree
    # @param env_name [String] Name for the ephemeral environment
    # @param parent_env [String] Parent environment to copy from
    # @return [Boolean] True on success
    def create_environment(worktree:, env_name:, parent_env:)
      return false unless belt_app?(worktree)

      LOG.info "[Belt] Creating ephemeral environment '#{env_name}' from parent '#{parent_env}'"

      env = BeltConfig.belt_cli_env(env_name)
      _, stderr, status = Open3.capture3(env, "belt", "g", "environment", env_name, parent_env, chdir: worktree)

      if status.success?
        LOG.info "[Belt] Successfully created environment '#{env_name}'"
        true
      else
        LOG.error "[Belt] Failed to create environment '#{env_name}': #{stderr.strip}"
        false
      end
    rescue StandardError => e
      LOG.error "[Belt] Error creating environment: #{e.message}"
      false
    end

    # Deploy to an environment.
    #
    # Always non-interactive: `belt deploy` prompts "Apply these changes? [y/N]"
    # unless `--auto` is passed. Open3.capture3 provides empty stdin, so without
    # `--auto` belt prints "Cancelled." and still exits 0 — a silent no-op.
    # Frontend-only uses `belt deploy frontend <env>` (subcommand first).
    #
    # @param worktree [String] Path to the worktree
    # @param env_name [String] Environment name
    # @param frontend_only [Boolean] If true, only deploy frontend
    # @return [Boolean] True on success
    def deploy(worktree:, env_name:, frontend_only: false, capture3: nil)
      return false unless belt_app?(worktree)

      cmd = deploy_command(env_name, frontend_only: frontend_only)
      env = BeltConfig.belt_cli_env(env_name)

      LOG.info "[Belt] Deploying to '#{env_name}'#{" (frontend only)" if frontend_only}"
      LOG.info "[Belt] Running: #{cmd.join(" ")} (in #{worktree})"

      runner = capture3 || Open3.method(:capture3)
      stdout, stderr, status = runner.call(env, *cmd, chdir: worktree)
      log_cli_tail(stdout, stderr)

      if deploy_cancelled?(stdout, stderr)
        LOG.error "[Belt] Deploy to '#{env_name}' cancelled — non-interactive belt deploy needs --auto"
        return false
      end

      if status.success?
        LOG.info "[Belt] Successfully deployed to '#{env_name}'"
        true
      else
        LOG.error "[Belt] Failed to deploy to '#{env_name}': #{stderr.strip}"
        false
      end
    rescue StandardError => e
      LOG.error "[Belt] Error deploying: #{e.message}"
      false
    end

    # argv for `belt deploy`. Extracted so tests can assert the command without
    # stubbing Open3 for every call site.
    def deploy_command(env_name, frontend_only: false)
      if frontend_only
        ["belt", "deploy", "frontend", env_name]
      else
        ["belt", "deploy", env_name, "--auto"]
      end
    end

    # Destroy an ephemeral environment.
    #
    # @param worktree [String] Path to the worktree (infrastructure lives here)
    # @param env_name [String] Environment name
    # @return [Boolean] True on success
    def destroy_environment(worktree:, env_name:)
      return false unless belt_app?(worktree)

      LOG.info "[Belt] Destroying ephemeral environment '#{env_name}'"

      env = BeltConfig.belt_cli_env(env_name)
      _, stderr, status = Open3.capture3(env, "belt", "destroy", "environment", env_name, "--full", chdir: worktree)

      if status.success?
        LOG.info "[Belt] Successfully destroyed environment '#{env_name}'"
        BeltConfig.mark_ephemeral_destroyed(env_name)
        true
      else
        LOG.error "[Belt] Failed to destroy environment '#{env_name}': #{stderr.strip}"
        false
      end
    rescue StandardError => e
      LOG.error "[Belt] Error destroying environment: #{e.message}"
      false
    end

    # Check if changes are frontend-only by examining the diff.
    # Frontend-only changes can be deployed faster with `belt deploy frontend <env>`.
    #
    # @param worktree [String] Path to the worktree
    # @param base_branch [String, nil] Optional base (e.g. "master", "origin/main").
    #   When omitted, uses origin/HEAD, then origin/main, then origin/master.
    # @return [Boolean] True if changes are frontend-only
    def frontend_only_changes?(worktree:, base_branch: nil)
      base_ref = resolve_frontend_diff_base(worktree, base_branch)
      unless base_ref
        LOG.warn "[Belt] No base ref for frontend-only check in #{worktree}"
        return false
      end

      stdout, stderr, status = Open3.capture3("git", "diff", "--name-only", base_ref, "--", chdir: worktree)
      unless status.success?
        LOG.warn "[Belt] Could not diff against #{base_ref}: #{stderr.strip}"
        return false
      end

      changed_files = stdout.strip.split("\n")
      return false if changed_files.empty?

      # Frontend directories that don't affect backend
      frontend_patterns = %w[
        frontend/
        app/javascript/
        app/assets/
        public/
        static/
        src/
      ]

      # Backend patterns that require full deploy
      backend_patterns = %w[
        lambda/
        infrastructure/
        config/routes
        config/contracts
        Gemfile
        *.gemspec
        Rakefile
      ]

      # Check if all changes are frontend-only
      changed_files.all? do |file|
        frontend_patterns.any? { |pattern| file.start_with?(pattern) } &&
          backend_patterns.none? { |pattern| file.start_with?(pattern.delete("*")) || File.fnmatch?(pattern, file) }
      end
    rescue StandardError => e
      LOG.warn "[Belt] Error checking frontend-only changes: #{e.message}"
      false
    end

    # Resolve a git ref to diff against. Never assumes origin/main.
    # Prefer an explicit PR/base branch, then origin/HEAD, then main/master.
    def resolve_frontend_diff_base(worktree, explicit)
      candidates = []
      if explicit && !explicit.to_s.strip.empty?
        ref = explicit.to_s.strip
        ref = "origin/#{ref}" unless ref.include?("/")
        candidates << ref
      end

      head = origin_head_branch(worktree)
      candidates << "origin/#{head}" if head
      candidates.push("origin/main", "origin/master")
      candidates.uniq.find { |ref| git_commit?(worktree, ref) }
    end

    def origin_head_branch(worktree)
      stdout, _stderr, status = Open3.capture3(
        "git", "symbolic-ref", "--short", "refs/remotes/origin/HEAD",
        chdir: worktree
      )
      return nil unless status.success?

      name = stdout.strip.delete_prefix("origin/")
      name.empty? ? nil : name
    rescue StandardError
      nil
    end

    def git_commit?(worktree, ref)
      _stdout, _stderr, status = Open3.capture3(
        "git", "rev-parse", "--verify", "#{ref}^{commit}",
        chdir: worktree
      )
      status.success?
    rescue StandardError
      false
    end

    def deploy_cancelled?(stdout, stderr)
      [stdout, stderr].any? { |s| s.to_s.match?(/\bCancelled\.?\s*$/) }
    end

    def log_cli_tail(stdout, stderr, limit: 25)
      lines = []
      lines.concat(stdout.to_s.lines) unless stdout.to_s.strip.empty?
      lines.concat(stderr.to_s.lines.map { |l| "stderr: #{l}" }) unless stderr.to_s.strip.empty?
      return if lines.empty?

      tail = lines.last(limit).join
      LOG.info "[Belt] Output (last #{[lines.size, limit].min} lines):\n#{tail}"
    end
  end
end

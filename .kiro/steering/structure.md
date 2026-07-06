# Project Structure

```
brainiac/
├── receiver.rb              # Entry point — Sinatra app, loads plugins, starts server
├── lib/
│   └── brainiac/
│       ├── hooks.rb         # Plugin hook/event system (Brainiac.on/emit)
│       ├── version.rb       # Brainiac::VERSION constant
│       ├── config.rb        # Environment, paths, constants, project/config loading
│       ├── agents.rb        # Agent registry, discovery, display names, env injection
│       ├── brain.rb         # Long-term memory: qmd queries, context building, git sync
│       ├── cron.rb          # Scheduled agent jobs and script execution
│       ├── helpers.rb       # Agent dispatch, model/effort detection, worktree management
│       ├── notifications.rb # Generic notification dispatch (plugins deliver)
│       ├── plugins.rb       # Gem-based plugin discovery, loading, lifecycle
│       ├── prompts.rb       # Prompt construction (core template + plugin channels)
│       ├── restart.rb       # Self-restart after code changes
│       ├── sessions.rb      # Active session tracking, supersede, kill, dispatch depth
│       ├── skills.rb        # Skill index and auto-injection
│       ├── users.rb         # Cross-platform user identity resolution
│       ├── routes/
│       │   └── api.rb       # Admin API endpoints (/api/*)
│       └── handlers/
│           └── shared/      # Shared utilities (git worktrees, inline tag parsing)
├── bin/                     # CLI executable (brainiac command)
├── monitor/                 # Status bar integrations (waybar, xbar)
├── templates/               # Example config files for ~/.brainiac/ setup
├── test/                    # Minitest test files (test_*.rb pattern)
├── tmp/                     # Agent session logs (gitignored)
├── docs/                    # Documentation
└── certs/                   # Gem signing certificate
```

## Architecture Pattern

- **Core + Plugins**: Core handles identity, brain, prompts, dispatch, hooks, and notifications. Plugins provide channel-specific communication.
- **Hook system**: `Brainiac.on(:event)` / `Brainiac.emit(:event)` — plugins subscribe to lifecycle events, core emits them.
- **Thin entry point**: `receiver.rb` loads modules, starts plugins, defines the Sinatra app.
- **Plugin loading**: Gems named `brainiac-<name>` are discovered from `~/.brainiac/plugins.json` and loaded at startup via `load_plugins!(app)`. Each plugin implements `.register(app)`.
- **Config reloading**: JSON configs at `~/.brainiac/` are checked for mtime changes and reloaded on each request.
- **Thread-based concurrency**: Cron, plugins, and background tasks run as Ruby threads.
- **No built-in channel handlers**: All communication channels (Discord, Fizzy, GitHub, Zoho) are external plugins. Core has zero knowledge of any specific channel's protocol.

## Plugin Architecture

Plugins are Ruby gems named `brainiac-<name>` that extend Brainiac without core knowing about them.

**Plugin contract:**
1. Gem entry file: `lib/brainiac_<name>.rb` (underscore, not hyphen)
2. Module: `Brainiac::Plugins::<Name>`
3. `.register(app)` — receives Sinatra::Application, defines routes, subscribes to hooks
4. `Brainiac.register_channel_prompt(:channel, prompt, pre_post_check: ...)` — register channel-specific prompt
5. Optional: `.cli(args)`, `.completions`, `.configured?`, `.help_text` for CLI integration

**Available hooks (emitted by core):**
- `:server_started` — after all plugins load
- `:agent_completed` — after agent session finishes (exit 0)
- `:agent_crashed` — agent process failed (non-zero exit)
- `:pre_dispatch` — before agent CLI is spawned
- `:notify` — notification dispatch (plugins deliver to their channel)
- `:build_brain_context` — inject source-specific brain queries
- `:pr_merged` — PR merged to default branch
- `:pr_review_received` — PR review submitted
- `:pr_synchronized` — PR updated (force push, new commits)
- `:production_deployed` — deploy workflow succeeded
- `:create_work_item` — create a card/issue/ticket
- `:detect_cli_provider` — detect CLI provider from metadata
- `:detect_effort` — detect effort level from metadata

## Runtime Config Location

All runtime configuration lives in `~/.brainiac/` (not in the repo). The repo's `templates/` directory has example configs. Brain data lives at `~/.brainiac/brain/`.

Plugins define their own config files when installed (e.g., `~/.brainiac/discord.json`).

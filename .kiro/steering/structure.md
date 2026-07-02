# Project Structure

```
brainiac/
├── receiver.rb              # Entry point — Sinatra app, loads plugins, starts server
├── lib/
│   ├── brainiac.rb          # Module loader (requires all core modules)
│   └── brainiac/
│       ├── hooks.rb         # Plugin hook/event system (Brainiac.on/emit)
│       ├── version.rb       # Brainiac::VERSION constant
│       ├── config.rb        # Environment, paths, constants, project/config loading
│       ├── agents.rb        # Agent registry, discovery, display names
│       ├── brain.rb         # Long-term memory: qmd queries, context building, git sync
│       ├── cron.rb          # Scheduled agent jobs
│       ├── helpers.rb       # Shared utility functions, agent dispatch, model/effort detection
│       ├── plugins.rb       # Gem-based plugin discovery, loading, lifecycle
│       ├── prompts.rb       # Prompt construction (core + Discord + GitHub channels)
│       ├── restart.rb       # Self-restart after code changes
│       ├── sessions.rb      # Active session tracking, supersede, kill
│       ├── skills.rb        # Skill index and auto-injection
│       ├── users.rb         # User lookup and identity resolution
│       └── handlers/
│           ├── discord.rb   # Discord bot gateway, message handling, REST API
│           ├── discord/     # Discord sub-modules (delivery, threads, reactions, etc.)
│           ├── github.rb    # GitHub webhook event handling
│           ├── shared/      # Shared handler logic (git, inline_tags)
│           └── zoho.rb      # Zoho Mail webhook handling
├── bin/                     # CLI executable (brainiac command)
├── monitor/                 # Status bar integrations (waybar, xbar)
├── templates/               # Example config files for ~/.brainiac/ setup
├── test/                    # Minitest test files (test_*.rb pattern)
├── tmp/                     # Agent session logs (gitignored)
├── docs/                    # Documentation
└── certs/                   # Gem signing certificate
```

## Architecture Pattern

- **Core + Plugins**: Core handles identity, brain, prompts, dispatch, and hooks. Plugins provide channel-specific communication (Fizzy, Discord, Slack, etc.)
- **Hook system**: `Brainiac.on(:event)` / `Brainiac.emit(:event)` for lifecycle integration between core and plugins
- **Thin entry point**: `receiver.rb` loads modules, starts plugins, defines routes
- **Handler pattern**: Built-in handlers (Discord, GitHub, Zoho) define webhook routes directly. External handlers (Fizzy, WhatsApp) are plugins.
- **Plugin loading**: Gems named `brainiac-<name>` are discovered and loaded at startup via `load_plugins!(app)`. Each plugin implements `.register(app)` to define routes and subscribe to hooks.
- **Config reloading**: JSON configs at `~/.brainiac/` are checked for mtime changes and reloaded on each webhook
- **Thread-based concurrency**: Discord bots, cron, plugins, and background tasks run as Ruby threads

## Plugin Architecture

Plugins are Ruby gems named `brainiac-<name>` that extend Brainiac without core knowing about them.

**Plugin contract:**
1. Gem entry file: `lib/brainiac-<name>.rb`
2. Module: `Brainiac::Plugins::<Name>`
3. `.register(app)` — receives Sinatra::Application, defines routes, subscribes to hooks
4. `Brainiac.register_channel_prompt(:channel, prompt)` — register channel-specific prompt

**Available hooks:**
- `:server_started` — after all plugins load (startup tasks)
- `:agent_completed` — after agent session finishes
- `:agent_crashed` — agent process crashed
- `:pre_dispatch` — before agent CLI is spawned
- `:build_brain_context` — inject source-specific brain queries
- `:pr_merged` — GitHub PR merged to main
- `:pr_review_received` — PR review submitted
- `:pr_synchronized` — PR updated (force push, new commits)
- `:production_deployed` — deploy workflow succeeded
- `:create_work_item` — create a card/issue/ticket
- `:detect_cli_provider` — detect CLI provider from metadata
- `:detect_effort` — detect effort level from metadata

## Runtime Config Location

All runtime configuration lives in `~/.brainiac/` (not in the repo). The repo's `templates/` directory has example configs. Brain data lives at `~/.brainiac/brain/`.

Plugins define their own config files (e.g., `~/.brainiac/fizzy.json`, `~/.brainiac/whatsapp.json`).

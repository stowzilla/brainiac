# Project Structure

```
brainiac/
├── receiver.rb              # Entry point — Sinatra app with all webhook routes and API endpoints
├── lib/
│   ├── brainiac.rb          # Module loader (requires all core modules)
│   ├── user_registry.rb     # Cross-platform user identity management
│   └── brainiac/
│       ├── version.rb       # Brainiac::VERSION constant
│       ├── config.rb        # Environment, paths, constants, project/config loading
│       ├── agents.rb        # Agent registry, discovery, dispatch logic
│       ├── brain.rb         # Long-term memory: qmd queries, context building, git sync
│       ├── card_index.rb    # Fizzy card duplicate detection (trigram + semantic)
│       ├── cron.rb          # Scheduled agent jobs
│       ├── deployments.rb   # Deployment environment tracking
│       ├── helpers.rb       # Shared utility functions
│       ├── planning.rb      # Planning mode (Q&A → plan → Fizzy steps)
│       ├── prompts.rb       # Prompt construction for agent dispatch
│       ├── sessions.rb      # Active session tracking, supersede, kill
│       ├── skills.rb        # Skill index and auto-injection
│       ├── users.rb         # User lookup and identity resolution
│       └── handlers/
│           ├── discord.rb   # Discord bot gateway, message handling, REST API
│           ├── fizzy.rb     # Fizzy webhook event handling
│           ├── github.rb    # GitHub webhook event handling
│           └── zoho.rb      # Zoho Mail webhook handling
├── bin/                     # CLI executable (brainiac command)
├── monitor/                 # Status bar integrations (waybar, xbar, menubar)
├── templates/               # Example config files for ~/.brainiac/ setup
├── test/                    # Minitest test files (test_*.rb pattern)
├── tmp/                     # Agent session logs (gitignored)
├── docs/                    # Documentation
└── certs/                   # Gem signing certificate
```

## Architecture Pattern

- **Flat module system**: All core logic lives as top-level methods in `lib/brainiac/*.rb` files (Sinatra DSL style, no classes)
- **Thin entry point**: `receiver.rb` defines routes and wires everything together
- **Handler pattern**: Each integration (Fizzy, GitHub, Discord, Zoho) has its own handler file
- **Config reloading**: JSON configs at `~/.brainiac/` are checked for mtime changes and reloaded on each webhook
- **Thread-based concurrency**: Discord bots, cron, and background tasks run as Ruby threads within the same process

## Runtime Config Location

All runtime configuration lives in `~/.brainiac/` (not in the repo). The repo's `templates/` directory has example configs. Brain data lives at `~/.brainiac/brain/`.

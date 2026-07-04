# Tech Stack

## Language & Runtime

- Ruby 3.4+ (see `.ruby-version`)
- Packaged as a gem (`brainiac.gemspec`)
- Extensible via plugin gems (`brainiac-<name>`)

## Dependencies

| Gem | Purpose |
|-----|---------|
| sinatra ~> 4.1 | HTTP webhook receiver |
| puma ~> 7.2 | Web server |
| rackup ~> 2.3 | Rack integration |

## Dev Dependencies

| Gem | Purpose |
|-----|---------|
| minitest ~> 5.25 | Test framework |
| rake ~> 13.0 | Task runner |
| rubocop ~> 1.75 | Linter |
| rubocop-performance ~> 1.25 | Performance cops |

## External Tools

| Tool | Purpose |
|------|---------|
| qmd | Brain semantic search and indexing |
| ngrok | Webhook tunneling |

Note: Brainiac is CLI-agnostic. The agent CLI (kiro-cli, grok, etc.) is configured per-project in `~/.brainiac/cli-providers/`. No specific CLI is a hard dependency of core.

## Common Commands

```bash
# Run tests
rake test

# Run linter
rake rubocop

# Run both (default task)
rake

# Start the server
brainiac server

# Install a plugin (from rubygems)
brainiac install discord

# Install a plugin (local dev)
brainiac install fizzy --path ~/Code/brainiac-fizzy

# List plugins
brainiac plugins
```

## Code Style

- RuboCop enforced (see `.rubocop.yml`)
- Double quotes for strings
- No frozen string literal comments required
- Max line length: 150
- Top-level method definitions allowed (Sinatra DSL style)

## Plugin Development

Plugins follow this contract:

1. Gem named `brainiac-<name>`
2. Entry file at `lib/brainiac_<name>.rb` (underscore in filename)
3. Module at `Brainiac::Plugins::<Name>`
4. `.register(app)` receives `Sinatra::Application` — define routes, subscribe to hooks
5. `Brainiac.register_channel_prompt(:channel, prompt)` for channel-specific prompts
6. Subscribe to hooks: `:agent_completed`, `:agent_crashed`, `:notify`, `:pre_dispatch`, etc.
7. Plugin state tracked in `~/.brainiac/plugins.json`
8. Plugin config in its own file (e.g., `~/.brainiac/discord.json`)
9. Optional CLI: `.cli(args)`, `.completions`, `.configured?`, `.help_text`

Use `brainiac plugin new <name>` to scaffold a new plugin.

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
| websocket-client-simple ~> 0.8 | Discord gateway connections |

## Dev Dependencies

| Gem | Purpose |
|-----|---------|
| minitest ~> 5.25 | Test framework |
| rake ~> 13.0 | Task runner |
| rubocop ~> 1.75 | Linter |
| rubocop-performance ~> 1.25 | Performance cops |

## Plugin Gems

Plugins extend Brainiac via separate gems:

| Gem | Purpose |
|-----|---------|
| brainiac-fizzy | Fizzy card management (extracted from core) |
| brainiac-whatsapp | WhatsApp Business API handler |

Install plugins: `brainiac install <name>` or `brainiac install <name> --path <dir>` for local dev.

## External Tools

| Tool | Purpose |
|------|---------|
| kiro-cli | Agent dispatch (spawned as subprocess) |
| gh (GitHub CLI) | PR/issue operations |
| qmd | Brain semantic search and indexing |
| ngrok | Webhook tunneling |

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

# Install a plugin
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
2. Entry file at `lib/brainiac-<name>.rb`
3. Module at `Brainiac::Plugins::<Name>`
4. `.register(app)` receives `Sinatra::Application` — define routes, subscribe to hooks
5. `Brainiac.register_channel_prompt(:channel, prompt)` for channel-specific prompts
6. Subscribe to hooks: `:agent_completed`, `:agent_crashed`, `:pre_dispatch`, etc.
7. Plugin state tracked in `~/.brainiac/plugins.json`
8. Plugin config in its own file (e.g., `~/.brainiac/fizzy.json`)

Reference implementation: `~/Code/brainiac-fizzy`

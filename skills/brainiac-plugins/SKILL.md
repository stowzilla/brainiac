---
name: brainiac-plugins
description: |
  Develop Brainiac plugins — gem-based handlers that extend Brainiac with new
  communication channels, integrations, or features. Covers the plugin contract,
  file structure, hooks, CLI commands, and the generator.
triggers:
  - brainiac plugin
  - create plugin
  - new plugin
  - plugin development
  - plugin contract
  - plugin hooks
  - brainiac handler
  - extend brainiac
---

# Brainiac Plugin Development

Plugins are Ruby gems named `brainiac-<name>` that extend Brainiac without modifying core.

## Quick Start

```bash
brainiac plugin new my-integration
cd brainiac-my-integration
bundle install
rake test          # Verify scaffold works
# Implement your logic...
brainiac install my-integration --path .
brainiac restart
```

## Plugin Contract

A valid Brainiac plugin MUST:

1. **Gem named `brainiac-<name>`** — e.g. `brainiac-discord`, `brainiac-slack`
2. **Entry file at `lib/brainiac_<name>.rb`** — loaded by RubyGems, requires the module
3. **Module at `Brainiac::Plugins::<Name>`** — PascalCase (e.g. `Discord`, `TestWidget`)
4. **Implement `.register(app)`** — receives `Sinatra::Application` at server startup

A plugin SHOULD also provide:

| Method | File | Purpose |
|--------|------|---------|
| `.register(app)` | main module | **Required.** Server startup — define routes, hooks, threads |
| `.configured?` | `metadata.rb` | Returns false → auto-runs setup on `brainiac install` |
| `.help_text` | `metadata.rb` | One-liner shown in `brainiac help` |
| `.cli(args)` | `cli.rb` | CLI subcommands via `brainiac <plugin> ...` |

## File Structure

```
brainiac-<name>/
├── lib/
│   ├── brainiac_<name>.rb                    # Entry point (require the module)
│   └── brainiac/plugins/<name>/
│       ├── version.rb                        # VERSION constant
│       ├── metadata.rb                       # help_text, configured? (lightweight, no deps)
│       ├── cli.rb                            # CLI subcommands (standalone, no server deps)
│       └── (your modules).rb                 # Server runtime code
├── test/
│   ├── test_helper.rb
│   └── test_<name>.rb
├── brainiac-<name>.gemspec
├── Gemfile, Rakefile, .rubocop.yml, README.md
```

### Critical Architecture: CLI vs Server Runtime

Plugins are loaded in TWO different contexts:

1. **Server context** — full plugin loaded via `.register(app)`. Has access to `LOG`, `AGENT_REGISTRY`, `PROJECTS`, `ACTIVE_SESSIONS`, and all core functions.

2. **CLI context** — only `metadata.rb` and `cli.rb` are loaded. NO server runtime available. These files MUST NOT require any module that depends on server constants.

This means:
- `metadata.rb` requires only `version.rb`
- `cli.rb` uses only stdlib (`json`, `net/http`, `fileutils`)
- Everything else (config, handlers, hooks) lives in separate files loaded only by `.register(app)`

## Hooks

Core emits lifecycle events. Subscribe in `.register(app)`:

```ruby
def register(app)
  Brainiac.on(:agent_completed) do |ctx|
    # ctx has :agent_name, :card_number, :exit_status, etc.
    move_card(ctx[:card_number], "done")
  end
end
```

Available hooks:

| Hook | When | Context |
|------|------|---------|
| `:server_started` | All plugins loaded | — |
| `:pre_dispatch` | Before agent CLI spawned | agent_name, project_config |
| `:agent_completed` | Agent session finished | agent_name, exit_status, source, card_number |
| `:agent_crashed` | Agent process crashed | agent_name, exit_status, log_file |
| `:build_brain_context` | Building prompt context | agent_name, card_title |
| `:pr_merged` | GitHub PR merged | pr_number, repo, branch |
| `:pr_review_received` | PR review submitted | pr_number, reviewer |
| `:pr_synchronized` | PR updated (new commits) | pr_number |
| `:production_deployed` | Deploy workflow succeeded | repo, environment |
| `:create_work_item` | Create a card/issue/ticket | title, body, project |
| `:detect_cli_provider` | Detect CLI provider | metadata hash |
| `:detect_effort` | Detect effort level | metadata hash |

## Channel Prompts

If your plugin is a communication channel (like Discord, Fizzy), register a prompt:

```ruby
def register(app)
  Brainiac.register_channel_prompt(:my_channel, MY_CHANNEL_PROMPT,
                                    pre_post_check: MY_PRE_POST_CHECK)
end
```

The prompt is prepended to every agent session dispatched through your channel. Use `{{PLACEHOLDERS}}` that `render_prompt` will fill.

## Routes

Define webhook and API routes on the Sinatra app:

```ruby
def register(app)
  app.post "/my-webhook" do
    content_type :json
    payload = JSON.parse(request.body.read)
    # Handle webhook...
    { status: "ok" }.to_json
  end

  app.get "/api/my-plugin" do
    content_type :json
    { enabled: true }.to_json
  end
end
```

## CLI Module Pattern

```ruby
module Brainiac::Plugins::MyPlugin
  module Cli
    class << self
      def run(args)
        case args.shift
        when "setup"  then cmd_setup
        when "config" then cmd_config
        else print_help
        end
      end
    end
  end

  def self.cli(args)
    Cli.run(args)
  end
end
```

CLI commands should manage config files at `~/.brainiac/<name>.json` and query the server API for status. They must NOT load server runtime modules.

## Core Functions Available in Server Context

When your plugin's `.register(app)` runs, these are available:

| Function | Purpose |
|----------|---------|
| `agent_display_name(key)` | Get display name for agent |
| `agent_env_for(name)` | Get env vars hash for agent |
| `AGENT_REGISTRY` | Hash of all agents |
| `PROJECTS` | Hash of all projects |
| `LOG` | Logger instance |
| `BRAINIAC_DIR` | Path to `~/.brainiac/` |
| `register_session(key, pid, **)` | Track active session |
| `session_active?(key)` | Check if session running |
| `build_brain_context(...)` | Build brain context for prompt |
| `render_prompt(template, vars, ...)` | Compose full prompt |
| `run_agent(...)` | Spawn agent CLI process |
| `detect_model(config, text:)` | Detect model from inline tags |
| `detect_effort(config, text:)` | Detect effort from inline tags |
| `parse_inline_tags(text)` | Parse [model], [project:X], etc. |
| `reload_projects!` | Reload projects.json |
| `reload_agent_registry!` | Reload agents.json |
| `brain_push(message:)` | Push brain changes to git |

## Testing

Generated test helpers stub all core constants and functions. Tests run without a server:

```bash
rake test       # Run minitest
rake rubocop    # Run linter
rake            # Both
```

## Publishing

```bash
gem build brainiac-<name>.gemspec
gem push brainiac-<name>-0.0.1.gem
```

Users install with:
```bash
brainiac install <name>
brainiac restart
```

## Reference Implementations

- `brainiac-discord` — Full communication channel (gateway, message handler, delivery, reactions, CLI)
- `brainiac-fizzy` — Card management (webhooks, hooks, duplicate detection, planning mode, CLI)

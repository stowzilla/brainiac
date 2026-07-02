# Product Summary

Brainiac is an AI agent orchestration platform. It manages agent identity, long-term memory, and prompt construction — then delegates communication channels to plugins.

## Core Concepts

- **Multi-agent system**: Multiple AI agents each with their own persona, brain, and roles. Agents are registered in `~/.brainiac/agents.json` with a `display_name` (human-readable canonical identity) and can use any CLI provider.
- **Plugin architecture**: Communication channels are plugins (`brainiac-fizzy`, `brainiac-whatsapp`, etc.) installed via `brainiac install <name>`. Core provides hooks; plugins subscribe to lifecycle events.
- **Hook system**: `Brainiac.on(:event)` / `Brainiac.emit(:event)` connects core lifecycle to plugin behavior. Plugins handle post-session actions, crash notifications, brain queries, metadata detection, and more.
- **Brain (long-term memory)**: Agents have persistent knowledge, persona, and per-session memory powered by qmd (semantic search). Brain syncs across machines via git.
- **Worktrees**: Card/ticket assignments create git worktrees so agents work in isolation.
- **Cross-agent collaboration**: Agents can @mention each other with loop prevention (dispatch depth limits).

## What Core Owns

- Agent identity (display_name, roles, env vars)
- Brain/prompt management (render_prompt, memory, persona, knowledge)
- Agent dispatch (run_agent, build_agent_cmd, CLI provider resolution)
- Hook system (lifecycle events)
- Generic detection from inline text ([cli:X], [effort:X], [model])
- Session tracking (active sessions, supersede, kill)
- Cron (scheduled tasks)

## What Plugins Own

- Channel-specific communication (routes, formatting, reactions, auth)
- Metadata-based detection (card tags, PR labels, etc. via hooks)
- Post-session actions (move cards, post status, close tickets via hooks)
- Their own configuration files
- Channel prompt (registered via `Brainiac.register_channel_prompt`)

## Key Integrations (via plugins)

| Plugin | Purpose |
|--------|---------|
| brainiac-fizzy | Fizzy card management (assignment, comments, dedup, deploys) |
| brainiac-whatsapp | WhatsApp Business API messaging |
| (built-in) Discord | Conversational agent access via per-agent bots |
| (built-in) GitHub | PR reviews, PR comments, PR merges, CI failures |
| (built-in) Zoho | Rule-based email notifications |

## Runtime

Runs as a single Sinatra server (default port 4567) with Discord bots as background threads. Uses ngrok for webhook tunneling. Config lives in `~/.brainiac/` as JSON files that reload dynamically. Plugins are loaded at startup.

## User Flow

```bash
gem install brainiac           # Install core
brainiac setup                 # Create ~/.brainiac/ structure + configs
brainiac install fizzy --path ~/Code/brainiac-fizzy  # Add plugins
brainiac register              # Register a project (from project dir)
brainiac server                # Start receiving webhooks
```

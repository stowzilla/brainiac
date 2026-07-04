# Product Summary

Brainiac is an AI agent orchestration platform. It manages agent identity, long-term memory, and prompt construction — then delegates communication channels to plugins.

No plugins are installed by default. Users install only the channels they need (e.g. `brainiac install discord`).

## Core Concepts

- **Multi-agent system**: Multiple AI agents each with their own persona, brain, and roles. Agents are registered in `~/.brainiac/agents.json` with a `display_name` and can use any CLI provider.
- **CLI-agnostic**: Brainiac spawns whatever agent CLI is configured in `~/.brainiac/cli-providers/`. Kiro, Grok, or any CLI that accepts prompts on stdin.
- **Plugin architecture**: Communication channels are plugins (`brainiac-<name>` gems) installed via `brainiac install <name>`. Core provides hooks; plugins subscribe to lifecycle events.
- **Hook system**: `Brainiac.on(:event)` / `Brainiac.emit(:event)` connects core lifecycle to plugin behavior.
- **Brain (long-term memory)**: Agents have persistent knowledge, persona, and per-session memory powered by qmd (semantic search). Brain syncs across machines via git.
- **Worktrees**: Work item assignments create git worktrees so agents work in isolation.
- **Cross-agent collaboration**: Agents can @mention each other with loop prevention (dispatch depth limits).
- **Notifications**: Generic `send_notification` emits `:notify` hook — plugins decide how to deliver (Discord, Slack, email, etc.).

## What Core Owns

- Agent identity (`agents.json` — display_name, roles, env vars, local flag)
- Brain/prompt management (`render_prompt`, memory, persona, knowledge)
- Agent dispatch (`run_agent`, CLI provider resolution, session tracking)
- Hook system (lifecycle event bus)
- Inline tag parsing (`[model]`, `[effort:X]`, `[plan]`, etc.)
- Session tracking (active sessions, supersede, kill)
- Cron (scheduled agent jobs and script execution)
- Notifications (generic dispatch via hooks)
- Work item map (branch→card mapping, worktree cleanup)
- User identity registry (cross-platform user resolution)

## What Plugins Own

- Channel-specific communication (webhook routes, formatting, reactions, auth)
- Channel-specific prompts (registered via `Brainiac.register_channel_prompt`)
- Post-session actions (move cards, post status, close tickets — via hooks)
- Crash notification delivery (via `:agent_crashed` hook)
- Their own configuration files (e.g., `~/.brainiac/discord.json`)
- CLI subcommands (e.g., `brainiac discord setup`)

## Runtime

Runs as a single Sinatra server (default port 4567). Uses ngrok for webhook tunneling. Config lives in `~/.brainiac/` as JSON files that reload dynamically. Plugins are loaded at startup via `load_plugins!`.

## User Flow

```bash
gem install brainiac           # Install core
brainiac setup                 # Create ~/.brainiac/ + first agent
brainiac register              # Register a project (from project dir)
brainiac install discord       # Add a plugin
brainiac server                # Start receiving webhooks
```

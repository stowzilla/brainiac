# Product Summary

Brainiac is an AI agent webhook receiver and dispatcher. It listens for events from Fizzy, GitHub, Discord, and Zoho Mail, then spawns AI agent CLIs (via kiro-cli) with natural language prompts.

## Core Concepts

- **Multi-agent system**: Multiple AI agents (Galen, GLaDOS, Kaylee, etc.) each with their own persona, brain, and Discord bot. Agents are registered in `~/.brainiac/agents.json` and can use any CLI provider (kiro-cli, grok, etc.) configured at the project, agent, or per-message level. Roles (general-engineer, test-engineer, etc.) are CLI-neutral markdown files at `~/.brainiac/roles/` injected into every prompt.
- **Webhook-driven**: Events arrive via HTTP webhooks → Brainiac routes them to the appropriate agent.
- **Brain (long-term memory)**: Agents have persistent knowledge, persona, and per-card memory powered by qmd (semantic search). Brain syncs across machines via git.
- **Worktrees**: Fizzy card assignments create git worktrees so agents work in isolation.
- **Cross-agent collaboration**: Agents can @mention each other with loop prevention (dispatch depth limits).
- **Planning mode**: `[plan]` tag makes agents gather requirements before coding.

## Key Integrations

| Source | Purpose |
|--------|---------|
| Fizzy | Card assignment, comments, @mentions, duplicate detection |
| GitHub | PR reviews, PR comments, PR merges, CI failures |
| Discord | Conversational agent access via per-agent bots |
| Zoho Mail | Rule-based email notifications |

## Runtime

Runs as a single Sinatra server (default port 4567) with Discord bots as background threads. Uses ngrok for webhook tunneling. Config lives in `~/.brainiac/` as JSON files that reload dynamically.

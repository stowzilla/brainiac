# Changelog

## Unreleased

- Multi-machine support through a `brainiac-hub`. With a `hub` block in `brainiac.json`, the server checks in with the hub, runs a tunnel (or reports a fixed public URL), acknowledges hub deliveries before running them, and only the leader machine runs cron and the Discord gateways. New `brainiac hub` and `brainiac machines` commands, new `:hub_leader_acquired` / `:hub_leader_lost` hooks. Off unless configured. See `docs/multi-machine.md`.

## 0.9.2 — 2026-11-02

- Add filesystem-search guardrail to PROMPT_CORE — forbids `find /`, `find ~`, `grep -r /`, and `locate`, which hang indefinitely on macOS (autofs, iCloud, sealed sim volumes). Teaches agents to use `gem which` / `Gem.loaded_specs` and scope `find` to known gem/repo roots with a depth limit.

## 0.9.1 — 2026-04-21

- Add subagent delegation section to PROMPT_CORE — teaches agents when/how to use `use_subagent` tool, with `brainiac list` for on-demand project discovery

## 0.9.0

- Add Pre-Post Comment Check and improve brain search topic extraction
- Include branch name in agent card completion comments
- Add branch name to fizzy PR merge comment
- Scope brain search mandate to non-standard CLI tools

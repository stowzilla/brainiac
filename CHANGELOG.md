# Changelog

## 0.2.0 — 2026-10-17

Minor release. Forensics & observability.

- **Log/retrieval forensics analyzer** (`lib/brainiac/forensics.rb`): correlates raw
  agent session logs with the durable session-history, flags anomalies (crashes,
  orphaned/stale logs, heavy context, slow runs, error signatures), and exposes a
  performance-over-time view with calibration recommendations. CLI: `brainiac forensics`
  (`--performance`, `--period`, `--since`, `--json`); API under `/api/forensics/*`.
- **Analytics web page** at `/analytics` — KPIs, inline-SVG trend chart, per-parameter
  inventory & drill-down, ROI/effectiveness (one-shot vs rework per card), and in-UI
  reading of skills/personas annotated with metric-derived pros/cons.
- **Going-forward session instrumentation** (schema v2): zero-token, zero-latency
  enrichment of each session record with trigger type, effort, resumed, branch,
  work item, prompt/output bytes, git impact, and a per-dispatch trace id.
- **Observability module** (`lib/brainiac/observability.rb`): consistent tagged
  component loggers, per-dispatch trace ids for cross-thread correlation, and a single
  `Brainiac.guard` for the rescue/log/swallow pattern — adopted by the hook emitter,
  completion steps, and forensics endpoints.
- `brainiac update` now confirms a 0.x → 0.y minor-version move before upgrading core.

## 0.9.1 — 2026-04-21

- Add subagent delegation section to PROMPT_CORE — teaches agents when/how to use `use_subagent` tool, with `brainiac list` for on-demand project discovery

## 0.9.0

- Add Pre-Post Comment Check and improve brain search topic extraction
- Include branch name in agent card completion comments
- Add branch name to fizzy PR merge comment
- Scope brain search mandate to non-standard CLI tools

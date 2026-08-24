# Resume Session Integration

Brainiac supports resuming prior agent sessions instead of starting fresh. Two patterns exist:

## Flag-Based Resume (e.g. Kiro `--resume`, Grok `-c`)

The CLI appends a flag to the existing command. The base command structure stays the same.

```
kiro-cli --agent sherlock chat --trust-all-tools --no-interactive --resume
grok --always-approve -c
```

Provider config:

```json
{
  "resume_flag": "--resume"
}
```

## Subcommand-Based Resume (e.g. Codex `exec resume --last`)

The CLI changes the subcommand entirely. The base command structure is replaced.

```
codex exec --full-auto          →  codex exec resume --last --full-auto
```

Provider config:

```json
{
  "resume_flag": null,
  "resume_args": "exec resume --last --full-auto",
  "session_dir": "~/.codex/sessions"
}
```

When `resume_args` is set, it replaces `default_args` entirely during resume. The `session_dir` field tells Brainiac where to look for prior sessions (for CLIs that store session state centrally rather than in the project directory).

## Plugin Integration Contract

Plugins that want to support resume MUST:

1. **Use `resume_viable?`** to check whether a session can be resumed:

   ```ruby
   can_resume = resume_viable?(project_config: config, chdir: worktree_path)
   ```

2. **Pass `resume: true` to `run_agent`** — core handles the rest:

   ```ruby
   run_agent(prompt, project_config: config, chdir: worktree_path, resume: can_resume)
   ```

Plugins MUST NOT:
- Check `resolved["resume_flag"]` directly (misses `resume_args` providers)
- Call `resolve_resume` directly (internal to `run_agent`)
- Build their own resume command logic

## How It Works Internally

```
Plugin calls run_agent(..., resume: true)
  → run_agent calls resolve_resume(true, resolved, chdir)
    → resolve_resume checks resume_flag OR resume_args is configured
    → resolve_resume calls prior_session_exists?(chdir, cli, session_dir:)
      → For centralized session dirs: scans .jsonl files for matching cwd
      → For local session dirs: checks for .grok/, .kiro-cli/, or recent logs
    → Returns :resume_args, flag string, or false
  → run_agent passes result to build_agent_cmd
    → :resume_args → replace default_args with resume_args
    → String flag → append to command
    → false → normal command (no resume)
```

## Session Detection

### Local (flag-based CLIs)

Checks for CLI-specific dotdirs (`.grok/`, `.kiro-cli/`) or recent agent logs in `tmp/` (last 24 hours).

### Centralized (subcommand-based CLIs)

Scans `session_dir` for `.jsonl` files modified in the last 24 hours whose first-line JSON metadata contains a `payload.cwd` matching the target working directory. Handles symlink resolution (e.g. `/var/folders` vs `/private/var/folders` on macOS).

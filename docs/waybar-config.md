# Agent Display Configuration (Waybar / xbar)

This file configures how agents appear in the status bar — waybar on Linux, xbar on macOS.

**Location:** `~/.brainiac/waybar.json`

## Example Configuration

```json
{
  "agents": [
    {
      "name": "Sherlock",
      "emoji": "🔍",
      "color": "green"
    },
    {
      "name": "Robin",
      "emoji": "🏹",
      "color": "blue"
    },
    {
      "name": "Merlin",
      "emoji": "🧙",
      "color": "purple"
    }
  ],
  "default_emoji": "❓",
  "schema_version": "1.0"
}
```

## Setting an agent's icon

You don't need to edit this file by hand. `brainiac agent create` asks for an
icon (or takes `--icon`), and `brainiac agent setup` asks for one if the agent
has none. To change one later:

```bash
brainiac agent setup "Judge Dredd" --icon ⚖️
```

The Omarchy bar plugin, waybar and xbar all read this file, so one entry covers
every bar. Agents without an entry show `default_emoji`.

## Fields

- **name**: Agent name (must match agent registry)
- **emoji**: Display emoji for waybar
- **color**: Terminal color for logs (red, green, blue, yellow, cyan, magenta, white)
- **default_emoji**: Fallback emoji when agent is unknown
- **schema_version**: Config format version

## Usage

Monitor scripts automatically load this file:
- `monitor/waybar.rb` - Waybar status display (Linux)
- `monitor/xbar.3s.rb` - xbar menu bar plugin (macOS)
- `monitor/daemon.rb` - Background monitor daemon
- `monitor/view-logs.rb` - Log viewer
- `monitor/view-logs-rofi.rb` - Rofi log selector

### Linux (Waybar)

```bash
ruby monitor/setup-waybar-module.rb   # One-time setup
omarchy restart waybar                 # Restart waybar
```

### macOS (xbar)

Requires [xbar](https://xbarapp.com) (free, formerly BitBar).

```bash
ruby monitor/setup-xbar-plugin.rb     # One-time setup (symlinks plugin)
# Restart xbar to activate
```

The xbar plugin reads from the same daemon socket as waybar. Make sure the monitor daemon is running:

```bash
ruby monitor/daemon.rb &
```

After editing agent config, restart brainiac:
```bash
brainiac restart
```


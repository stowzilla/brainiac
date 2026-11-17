# Running Brainiac on more than one machine

Run the same agents on several machines without two of them answering the same event.

- [How it works](#how-it-works)
- [What you need](#what-you-need)
- [Part 1: Deploy the hub (once)](#part-1-deploy-the-hub-once)
- [Part 2: Connect the machine you already run](#part-2-connect-the-machine-you-already-run)
- [Part 3: Add another machine](#part-3-add-another-machine)
- [Choosing which machine does the work](#choosing-which-machine-does-the-work)
- [Discord and cron: the leader](#discord-and-cron-the-leader)
- [Tunnels: how the hub reaches a machine](#tunnels-how-the-hub-reaches-a-machine)
- [When a machine is offline](#when-a-machine-is-offline)
- [Commands](#commands)
- [Settings reference](#settings-reference)
- [Limits](#limits)
- [Troubleshooting](#troubleshooting)

## How it works

```
Fizzy / GitHub / other webhooks
              |
        brainiac-hub              a small cloud app (AWS Lambda + DynamoDB)
   picks ONE machine per event
      /        |         \
  main box   mini-PC   Windows (WSL2)
  each runs `brainiac server` and a tunnel the hub can push to
```

- **The hub** is the only address your webhooks point at. For each event it picks one machine and pushes the event to it. It never runs agents and holds no webhook secrets or bot tokens.
- **A machine** (a "node") runs `brainiac server` as usual. On start it checks in with the hub: "I'm `mini`, reach me at this URL". It checks in again every two minutes.
- **Work is sticky.** The first event for a card picks a machine. Every later event for that card, its branch and its pull request goes to the same machine, because the worktree and the CLI session live there.
- **One machine is the leader.** Discord delivers messages over a connection that has to stay open, which a serverless hub cannot hold. So one machine holds the Discord connections and runs cron. If it goes away, another machine takes over.

Nothing changes on a machine with no `hub` settings. Single-machine setups keep working as they are.

## What you need

- An AWS account for the hub. Expect roughly $0 to $1 a month: three machines checking in every two minutes is about 65,000 requests a month.
- On every machine: Brainiac, your plugins, your agent CLIs logged in, your repos cloned, and a tunnel (see [Tunnels](#tunnels-how-the-hub-reaches-a-machine)). `cloudflared` is free and needs no account.
- `brainiac-discord` at a version with leader support, if you use Discord. An older plugin opens the Discord connections on every machine and every bot answers once per machine.
- Windows machines run Brainiac inside WSL2. Follow the Linux steps there.

## Part 1: Deploy the hub (once)

The hub lives in its own repository, `brainiac-hub`. Its README has the full deploy steps. The short version:

```bash
git clone <your brainiac-hub repo> && cd brainiac-hub
bundle install
belt setup state          # once per AWS account: S3 bucket for Terraform state
belt deploy prod
belt output prod          # prints api_url
```

You need two values from the deploy:

1. **Hub URL**: the `api_url` output, for example `https://abc123.execute-api.us-east-1.amazonaws.com/prod`.
2. **Node token**: the shared secret every machine uses.

   ```bash
   aws ssm get-parameter --name /brainiac-hub/prod/node_token \
     --with-decryption --query Parameter.Value --output text
   ```

## Part 2: Connect the machine you already run

Do this on the machine that runs Brainiac today.

**1. Update Brainiac and the Discord plugin**, then install a tunnel:

```bash
brainiac update
# Arch:           sudo pacman -S cloudflared
# macOS:          brew install cloudflared
# Debian/Ubuntu:  see "Tunnels" below
```

**2. Point this machine at the hub.**

```bash
brainiac hub setup \
  --url https://abc123.execute-api.us-east-1.amazonaws.com/prod \
  --token <node token> \
  --machine main \
  --priority 20 \
  --tunnel cloudflared
brainiac restart
brainiac machines        # should list "main" as online and as the leader
```

If this machine already has a public address (an ngrok static domain, a named Cloudflare tunnel), use `--public-url https://...` instead of `--tunnel cloudflared` and keep running that tunnel yourself.

**3. Move your webhooks to the hub.** The path after `/hooks` is the path the plugin serves on a machine.

| Plugin | Old URL (your tunnel) | New URL (the hub) |
|---|---|---|
| Fizzy | `https://<tunnel>/fizzy/<board>` | `https://<hub>/hooks/fizzy/<board>` |
| GitHub | `https://<tunnel>/github` | `https://<hub>/hooks/github` |
| Zoho | `https://<tunnel>/zoho` | `https://<hub>/hooks/zoho` |
| Basecamp | `https://<tunnel>/basecamp` | `https://<hub>/hooks/basecamp` |

For Fizzy, the plugin can do it: `brainiac fizzy board webhook <board> https://<hub>/hooks/fizzy/<board>`. For GitHub, change the Payload URL in the app or repository webhook settings and keep the content type as `application/json`. Leave the secrets alone: the hub forwards the body and signature untouched, and the machine checks them as before.

**4. Test it.** Comment on a card. `brainiac logs` on the machine shows a line like `[Hub] Job <id> /fizzy/<board> -> 200`.

At this point you have one machine behind the hub. Everything behaves as before, and you can add machines.

## Part 3: Add another machine

Each machine is a complete Brainiac install that can run any of your agents. The hub decides which one gets each job.

**1. Install the basics** (see the main README's prerequisites): Ruby 3.4+, your agent CLIs (`claude`, `kiro-cli`, ...) **logged in**, `git`, `gh` (logged in), `qmd`, and any plugin CLIs you use (`fizzy`, ...).

```bash
gem install brainiac
brainiac setup
brainiac install discord     # the same plugins as your first machine
brainiac install fizzy
brainiac install github
```

**2. Copy your configuration from the first machine.** These files in `~/.brainiac/` describe your agents and integrations and must match across machines:

| File | Why |
|---|---|
| `agents.json` | Agents, their tokens, and `"local": true`. An agent only runs on a machine where it is local. |
| `fizzy.json`, `github.json`, `discord.json`, other plugin files | Webhook secrets and plugin settings. Any machine may be the one that verifies a webhook. |
| `users.json`, `roles/`, `cli-providers/`, `profiles.json` | Identity, roles and CLI settings |
| `cron.json` | Only if this machine may become the leader |

Do **not** copy `brainiac.json` wholesale (it holds this machine's hub settings), `projects.json` (paths differ per machine), `work_items.json`, or `tmp/`. They are per machine.

```bash
# from the first machine
cd ~/.brainiac
scp -r agents.json users.json fizzy.json github.json discord.json roles cli-providers newbox:.brainiac/
```

These files contain tokens. Copy them over SSH, not through chat or email.

**3. Clone the brain.** The brain is a git repository (see "Git Sync" in the README). Every machine pulls it before a session and pushes after, which is how memory follows the work.

```bash
git clone <your brain repo> ~/.brainiac/brain
brainiac brain init
```

**4. Clone and register your projects.** Paths can differ between machines.

```bash
git clone git@github.com:yourorg/my-app.git ~/Code/my-app
cd ~/Code/my-app && brainiac register
```

A machine only takes work for projects it has registered. If a project is missing, events for it are ignored on that machine.

**5. Install the tunnel and connect to the hub.**

```bash
sudo pacman -S cloudflared       # or brew / apt, see "Tunnels"
brainiac hub setup \
  --url https://abc123.execute-api.us-east-1.amazonaws.com/prod \
  --token <node token> \
  --machine mini \
  --priority 10 \
  --tunnel cloudflared
brainiac server --daemon
brainiac machines
```

`brainiac machines` on any machine should now show both, one of them marked leader.

**6. Send it some work.** Add the tag `machine:mini` to a Fizzy card and assign it to an agent. `brainiac hub assignments fizzy:` shows where each card lives.

## Choosing which machine does the work

For **new work** the hub picks, in this order:

1. **The machine you asked for**, if it is online:
   - Fizzy: a card tag `machine:<name>` (also `machine-<name>`).
   - Any webhook: `?machine=<name>` on the webhook URL. A board whose webhook is `https://<hub>/hooks/fizzy/<board>?machine=gpu` sends all its new cards to `gpu`.
2. **The online machine with the lowest `priority` number.** If the machine you asked for is offline, this is the fallback: priorities are your fallback order.
3. If no machine is online, the event waits in the hub for the first machine that checks in.

For **work that already has an owner** (a card someone started, its branch, its pull request) the hub always uses the owner. To move it:

```bash
brainiac hub move fizzy:1834 gpu      # push the branch on the old machine first
brainiac hub release fizzy:1834       # or: forget the owner, let the next event choose
```

The new machine starts from the pushed branch and the brain's memory. The CLI's own conversation history stays on the old machine.

**GitHub events** carry a branch, not a card. The hub maps them two ways: a branch named `fizzy-<number>-...` follows that card, and each machine reports the branches it has worktrees for when it checks in.

## Discord and cron: the leader

One machine at a time is the leader. The leader:

- holds the Discord connection for every bot, so **Discord conversations run on the leader**
- runs `cron.json`
- runs the daily skill curation

Any machine can still post to Discord (a Fizzy job on `mini` posts its own notifications): posting does not need the open connection.

The leader is whichever machine asked first. It keeps the role until it shuts down or stops checking in. A clean shutdown hands over within one check-in (two minutes by default). After a crash or network loss it takes up to about nine minutes: the hub waits three missed check-ins before it gives the role to someone else. A leader that cannot reach the hub drops the role by itself after two missed check-ins, before another machine can pick it up, so two machines never answer at once.

To keep the role off a machine, set `--no-leader` on it. To pick the leader, set `--no-leader` on every machine except the one you want. Cron jobs must exist on every machine that may lead.

## Tunnels: how the hub reaches a machine

The hub pushes over HTTPS, so each machine needs a public URL that forwards to `localhost:4567`.

| | Cloudflare quick tunnel | Cloudflare named tunnel | ngrok |
|---|---|---|---|
| Cost | Free | Needs a domain you own with its DNS on Cloudflare. Check Cloudflare's current plans for Tunnel pricing | Free plan: one domain per account. Several machines need a paid plan or several accounts |
| Account | None | Cloudflare account, domain's DNS on Cloudflare | ngrok account |
| URL | New random URL on every start | Fixed hostname you choose | Fixed (one free dev domain) |
| Setup | `--tunnel cloudflared` | About ten minutes per machine | Run ngrok yourself, `--public-url` |
| Limits | "No uptime guarantee", 200 requests in flight, meant for testing and development | Cloudflare's production offering | See ngrok's plan limits |

**Recommended: the quick tunnel.** A changing URL is normally a problem with webhooks, and here it is not: Brainiac starts `cloudflared`, reads the new URL and reports it to the hub on every start, and restarts the tunnel if it dies. Your webhooks only ever know the hub's URL. The cost is Cloudflare's "no uptime guarantee" wording. If a quick tunnel drops, events for that machine wait in the hub until it is back (see [When a machine is offline](#when-a-machine-is-offline)).

Install `cloudflared`:

```bash
# Arch
sudo pacman -S cloudflared

# macOS
brew install cloudflared

# Debian / Ubuntu (including WSL2)
sudo mkdir -p --mode=0755 /usr/share/keyrings
curl -fsSL https://pkg.cloudflare.com/cloudflare-main.gpg | sudo tee /usr/share/keyrings/cloudflare-main.gpg >/dev/null
echo 'deb [signed-by=/usr/share/keyrings/cloudflare-main.gpg] https://pkg.cloudflare.com/cloudflared any main' | sudo tee /etc/apt/sources.list.d/cloudflared.list
sudo apt-get update && sudo apt-get install cloudflared
```

Check it by hand once: `cloudflared tunnel --url http://localhost:4567` prints a `https://<words>.trycloudflare.com` URL. Stop it again; Brainiac runs its own.

**A fixed hostname with a named tunnel** (needs a domain on Cloudflare):

```bash
cloudflared tunnel login
cloudflared tunnel create brainiac-mini
cloudflared tunnel route dns brainiac-mini mini.example.com
cat > ~/.cloudflared/config.yml <<'EOF'
url: http://localhost:4567
tunnel: <Tunnel-UUID>
credentials-file: /home/<you>/.cloudflared/<Tunnel-UUID>.json
EOF
cloudflared tunnel run brainiac-mini      # or install it as a service
brainiac hub setup --public-url https://mini.example.com
```

**ngrok or anything else:** run it yourself and give Brainiac the URL: `brainiac hub setup --public-url https://your-name.ngrok-free.app`.

A tunnel exposes the whole Brainiac server, as your ngrok tunnel does today. Set `dashboard_token` in `brainiac.json` so the dashboard and `/api/*` are not open to anyone who learns the URL.

## When a machine is offline

| Situation | What happens |
|---|---|
| New work, requested machine offline | Goes to the next online machine by priority |
| New work, nothing online | Waits in the hub (up to 24 hours) for the first machine to check in |
| Follow-up for a card owned by an offline machine | Waits in the hub for that machine. It does not move by itself. Use `brainiac hub move` to move it |
| A machine misses one push | The hub marks it unreachable and stops pushing until its next check-in (within two minutes), then hands over what queued |
| Leader goes offline | Another machine takes over Discord and cron |
| The hub itself is unreachable | Machines keep running what they have. No new webhooks arrive until it is back. The leader steps down after two missed check-ins, so Discord goes quiet too |

`brainiac machines` shows what is waiting and for whom.

## Commands

```bash
brainiac machines                    # who is online, who leads, what is queued
brainiac hub setup [options]         # connect this machine (see Settings reference)
brainiac hub show                    # this machine's hub settings (token hidden)
brainiac hub assignments [prefix]    # owners, e.g. `fizzy:` or `branch:yourorg/my-app:`
brainiac hub move <key> <machine>    # move a card or branch
brainiac hub release <key>           # forget the owner
brainiac hub disable                 # back to a standalone machine
```

Keys look like `fizzy:1834`, `branch:yourorg/my-app:fizzy-1834-fix-login` and `pr:yourorg/my-app:212`.

## Settings reference

`brainiac hub setup` writes this block to `~/.brainiac/brainiac.json`:

```json
{
  "hub": {
    "url": "https://abc123.execute-api.us-east-1.amazonaws.com/prod",
    "token": "<node token>",
    "machine": "mini",
    "priority": 10,
    "leader": true,
    "interval": 120,
    "tunnel": "cloudflared"
  }
}
```

| Key | Default | Meaning |
|---|---|---|
| `url` | none | Hub base URL. With `token`, this switches multi-machine on |
| `token` | none | Node token. The `BRAINIAC_HUB_TOKEN` environment variable wins over the file |
| `machine` | hostname | This machine's name: lowercase letters, digits, `.`, `-`, `_` |
| `priority` | `100` | Lower number is preferred for new work |
| `leader` | `true` | Whether this machine may hold Discord and cron |
| `interval` | `120` | Seconds between check-ins. Lower means faster failover and more requests |
| `tunnel` | none | `"cloudflared"`, or `{ "command": [...], "url_pattern": "regex" }` for another tool. `%<port>d` in the command becomes the server port |
| `public_url` | none | A fixed public URL for this machine. Used instead of `tunnel` |

Restart the server after changing any of these.

## Limits

- **Discord work runs on the leader.** You cannot yet send a Discord conversation to a chosen machine. Use `--no-leader` to control which machine leads.
- **In-flight work does not move by itself.** See [When a machine is offline](#when-a-machine-is-offline).
- **A queued event can go stale.** Senders that sign a timestamp (the Posh Nosh plugin allows five minutes) reject an event that waited longer than that.
- **OAuth setup pages** (`/zoho/auth`, `/zoho/callback`) are not served through the hub. Run those against a machine directly.
- **The monitor and dashboard show one machine.** Each shows the sessions on its own machine.
- **Agents that only one machine has.** If an agent is `local` on one machine only, send its work there with a tag or `?machine=`. Otherwise another machine may receive the event and ignore it.

## Troubleshooting

**`brainiac machines` says it could not reach the hub.** Check `brainiac hub show` for the URL, and that the token matches the one in SSM.

**A machine shows OFFLINE while its server is running.** Look in `brainiac logs` for `[Hub]` lines. `No public URL yet` means the tunnel has not produced a URL: check that `cloudflared` is installed and runs by hand. `POST /nodes -> 401` means the token is wrong.

**Webhooks arrive at the hub but nothing happens.** `brainiac machines` shows whether they are queued. If a machine is online and still gets nothing, its tunnel URL may be dead: restart the server to get a new one.

**The machine logs `Job ... -> 401`.** The hub delivered the event and the plugin rejected the signature. That machine's webhook secret (`fizzy.json`, `github.json`) does not match the first machine's.

**Two bots answer every Discord message.** One machine runs a Discord plugin without leader support. Update it there.

**Discord is quiet.** `brainiac machines` shows the leader. If it says `nobody`, every machine has `leader: false` or none is online.

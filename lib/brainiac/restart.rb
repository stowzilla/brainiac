# frozen_string_literal: true

# Brainiac self-restart logic.
#
# When an agent works on brainiac itself (modifies code), a restart is queued.
# A background thread checks every 30s and only restarts when no other agents
# are running, preventing mid-session kills.
#
# This is NOT Discord-specific — it was previously in the Discord handler
# because Discord agents trigger restarts most often, but any source can queue one.

BRAINIAC_RESTART_STATE = { queued: false, triggered_by: nil }
BRAINIAC_RESTART_MUTEX = Mutex.new

def queue_brainiac_restart(agent_name)
  BRAINIAC_RESTART_MUTEX.synchronize do
    unless BRAINIAC_RESTART_STATE[:queued]
      BRAINIAC_RESTART_STATE[:queued] = true
      BRAINIAC_RESTART_STATE[:triggered_by] = agent_name
      LOG.info "[Brainiac] #{agent_name} queued a restart — will execute when all agents finish"
    end
  end
end

# Send a Discord notification about brainiac restart/startup using any available bot token.
def send_restart_notification(message)
  channel_id = DISCORD_CONFIG["notification_channel_id"]
  return unless channel_id

  tokens = discord_bot_tokens
  triggered_by = BRAINIAC_RESTART_MUTEX.synchronize { BRAINIAC_RESTART_STATE[:triggered_by] }
  token = tokens[triggered_by&.downcase] || tokens.values.first
  return unless token

  send_discord_message(channel_id, message, token: token)
rescue StandardError => e
  LOG.warn "[Brainiac] Failed to send restart notification: #{e.message}"
end

def any_agents_running?
  ACTIVE_SESSIONS_MUTEX.synchronize do
    ACTIVE_SESSIONS.any? do |_key, info|
      Process.kill(0, info[:pid])
      true
    rescue Errno::ESRCH, Errno::EPERM
      false
    end
  end
end

def execute_restart
  triggered_by = BRAINIAC_RESTART_MUTEX.synchronize { BRAINIAC_RESTART_STATE[:triggered_by] }
  LOG.info "[Brainiac] All agents finished, executing restart..."
  BRAINIAC_RESTART_MUTEX.synchronize { BRAINIAC_RESTART_STATE[:queued] = false }

  send_restart_notification("🔄 Restarting brainiac (triggered by #{triggered_by || "unknown"})...")

  Thread.new do
    sleep 1
    source_dir = defined?(SERVER_ROOT) ? SERVER_ROOT : File.expand_path("../..", __dir__)
    receiver_path = File.join(source_dir, "receiver.rb")

    # Determine if we're running in foreground mode.
    # If stdin is a TTY or we weren't launched as a daemon, use exec to replace the process.
    # This keeps the server in the foreground terminal.
    foreground = $stdout.tty? || !File.exist?(File.join(BRAINIAC_DIR, "server.pid")) ||
                 File.read(File.join(BRAINIAC_DIR, "server.pid")).strip.to_i == Process.pid

    if foreground
      LOG.info "[Brainiac] Restarting in foreground mode (exec)..."
      # Write PID file for the new process (same PID after exec)
      File.write(File.join(BRAINIAC_DIR, "server.pid"), Process.pid.to_s)

      # exec replaces this process — the terminal stays attached
      Dir.chdir(source_dir)
      exec("ruby", receiver_path)
    else
      # Daemon mode — spawn a new background process
      log_file = File.join(source_dir, "tmp", "brainiac-server.log")
      FileUtils.mkdir_p(File.dirname(log_file))

      pid = spawn({ "PATH" => ENV.fetch("PATH", nil) }, "ruby", receiver_path,
                  chdir: source_dir, out: [log_file, "a"], err: %i[child out])
      Process.detach(pid)

      File.write(File.join(BRAINIAC_DIR, "server.pid"), pid.to_s)

      LOG.info "[Brainiac] Stopping server, new instance started (PID: #{pid}) from #{source_dir}"
      sleep 0.5
      Sinatra::Application.quit!
      sleep 0.5
      exit!
    end
  end
end

def start_brainiac_restart_monitor
  Thread.new do
    LOG.info "[Brainiac] Restart monitor started, checking every 30s"
    loop do
      sleep 30
      restart_needed = BRAINIAC_RESTART_MUTEX.synchronize { BRAINIAC_RESTART_STATE[:queued] }

      if restart_needed && !any_agents_running?
        execute_restart
      elsif restart_needed
        active_count = ACTIVE_SESSIONS_MUTEX.synchronize { ACTIVE_SESSIONS.size }
        LOG.info "[Brainiac] Restart queued but #{active_count} agent(s) still running, waiting..."
      end
    end
  end
end

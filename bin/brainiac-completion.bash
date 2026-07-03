_brainiac() {
  local cur prev words cword
  COMPREPLY=()
  cur="${COMP_WORDS[COMP_CWORD]}"
  prev="${COMP_WORDS[COMP_CWORD-1]}"
  words=("${COMP_WORDS[@]}")
  cword=$COMP_CWORD

  local brainiac_dir="${BRAINIAC_DIR:-$HOME/.brainiac}"

  # Top-level commands (built-in + installed plugins)
  local commands="server stop restart logs status register unregister list show brain cron provider role agent config path version help setup projects card-map handler plugin install uninstall plugins"

  # Add installed plugin names as top-level commands
  if [[ -f "$brainiac_dir/plugins.json" ]]; then
    local plugin_names
    plugin_names=$(ruby -rjson -e '
      config = JSON.parse(File.read(ARGV[0]))
      (config["plugins"] || []).each { |p| puts p.is_a?(Hash) ? p["name"] : p.to_s }
    ' "$brainiac_dir/plugins.json" 2>/dev/null)
    commands="$commands $plugin_names"
  fi

  # Helper: list agent keys from registry
  _brainiac_agents() {
    if [[ -f "$brainiac_dir/agents.json" ]]; then
      ruby -rjson -e 'JSON.parse(File.read(ARGV[0])).each_key { |k| puts k }' "$brainiac_dir/agents.json" 2>/dev/null
    fi
  }

  # Helper: list role names from roles directory
  _brainiac_roles() {
    if [[ -d "$brainiac_dir/roles" ]]; then
      ls "$brainiac_dir/roles/"*.md 2>/dev/null | xargs -I{} basename {} .md
    fi
  }

  # Helper: list provider names
  _brainiac_providers() {
    if [[ -d "$brainiac_dir/cli-providers" ]]; then
      ls "$brainiac_dir/cli-providers/"*.json 2>/dev/null | xargs -I{} basename {} .json
    fi
  }

  # Helper: list project keys
  _brainiac_projects() {
    if [[ -f "$brainiac_dir/projects.json" ]]; then
      ruby -rjson -e 'JSON.parse(File.read(ARGV[0])).each_key { |k| puts k }' "$brainiac_dir/projects.json" 2>/dev/null
    fi
  }

  # Determine position in command
  case $cword in
    1)
      COMPREPLY=($(compgen -W "$commands" -- "$cur"))
      return
      ;;
  esac

  local cmd="${words[1]}"

  case "$cmd" in
    plugin)
      case $cword in
        2)
          COMPREPLY=($(compgen -W "new" -- "$cur"))
          ;;
      esac
      ;;

    role)
      case $cword in
        2)
          COMPREPLY=($(compgen -W "list show create assign unassign" -- "$cur"))
          ;;
        3)
          local subcmd="${words[2]}"
          case "$subcmd" in
            assign|unassign)
              COMPREPLY=($(compgen -W "$(_brainiac_agents)" -- "$cur"))
              ;;
            show)
              COMPREPLY=($(compgen -W "$(_brainiac_roles)" -- "$cur"))
              ;;
          esac
          ;;
        4)
          local subcmd="${words[2]}"
          case "$subcmd" in
            assign|unassign)
              COMPREPLY=($(compgen -W "$(_brainiac_roles)" -- "$cur"))
              ;;
          esac
          ;;
      esac
      ;;

    agent)
      case $cword in
        2)
          COMPREPLY=($(compgen -W "list create remove $(_brainiac_agents)" -- "$cur"))
          ;;
        3)
          local agent_name="${words[2]}"
          case "$agent_name" in
            list|remove|delete|rm) ;;
            create|add)
              COMPREPLY=($(compgen -W "--local --role --cli --persona" -- "$cur"))
              ;;
            *)
              COMPREPLY=($(compgen -W "show env" -- "$cur"))
              ;;
          esac
          ;;
        4)
          local subcmd="${words[3]}"
          if [[ "$subcmd" == "env" ]]; then
            local agent_key="${words[2]}"
            local env_keys=""
            if [[ -f "$brainiac_dir/agents.json" ]]; then
              env_keys=$(ruby -rjson -e '
                reg = JSON.parse(File.read(ARGV[0]))
                entry = reg[ARGV[1]] || reg[ARGV[1].downcase]
                (entry&.dig("env") || {}).each_key { |k| puts k }
              ' "$brainiac_dir/agents.json" "$agent_key" 2>/dev/null)
            fi
            COMPREPLY=($(compgen -W "--delete $env_keys" -- "$cur"))
          fi
          ;;
        5)
          if [[ "${words[3]}" == "env" && "${words[4]}" == "--delete" ]]; then
            local agent_key="${words[2]}"
            local env_keys=""
            if [[ -f "$brainiac_dir/agents.json" ]]; then
              env_keys=$(ruby -rjson -e '
                reg = JSON.parse(File.read(ARGV[0]))
                entry = reg[ARGV[1]] || reg[ARGV[1].downcase]
                (entry&.dig("env") || {}).each_key { |k| puts k }
              ' "$brainiac_dir/agents.json" "$agent_key" 2>/dev/null)
            fi
            COMPREPLY=($(compgen -W "$env_keys" -- "$cur"))
          fi
          ;;
      esac
      ;;

    provider)
      case $cword in
        2)
          COMPREPLY=($(compgen -W "list show add" -- "$cur"))
          ;;
        3)
          local subcmd="${words[2]}"
          if [[ "$subcmd" == "show" ]]; then
            COMPREPLY=($(compgen -W "$(_brainiac_providers)" -- "$cur"))
          fi
          ;;
      esac
      ;;

    brain)
      case $cword in
        2)
          COMPREPLY=($(compgen -W "init status search list path" -- "$cur"))
          ;;
        3)
          local subcmd="${words[2]}"
          if [[ "$subcmd" == "init" || "$subcmd" == "status" ]]; then
            COMPREPLY=($(compgen -W "$(_brainiac_agents)" -- "$cur"))
          fi
          ;;
      esac
      ;;

    cron)
      case $cword in
        2)
          COMPREPLY=($(compgen -W "add list remove enable disable update" -- "$cur"))
          ;;
      esac
      ;;

    projects)
      case $cword in
        2)
          COMPREPLY=($(compgen -W "list default" -- "$cur"))
          ;;
        3)
          if [[ "${words[2]}" == "default" ]]; then
            COMPREPLY=($(compgen -W "$(_brainiac_projects)" -- "$cur"))
          fi
          ;;
      esac
      ;;

    install)
      # Suggest known plugin names that aren't installed
      if [[ $cword -eq 2 ]]; then
        COMPREPLY=($(compgen -W "--path --version" -- "$cur"))
      fi
      ;;

    uninstall)
      if [[ $cword -eq 2 && -f "$brainiac_dir/plugins.json" ]]; then
        local installed
        installed=$(ruby -rjson -e '
          config = JSON.parse(File.read(ARGV[0]))
          (config["plugins"] || []).each { |p| puts p.is_a?(Hash) ? p["name"] : p.to_s }
        ' "$brainiac_dir/plugins.json" 2>/dev/null)
        COMPREPLY=($(compgen -W "$installed" -- "$cur"))
      fi
      ;;

    *)
      # Check if cmd is an installed plugin — delegate completion to it
      if [[ -f "$brainiac_dir/plugins.json" ]]; then
        local is_plugin
        is_plugin=$(ruby -rjson -e '
          config = JSON.parse(File.read(ARGV[0]))
          names = (config["plugins"] || []).map { |p| p.is_a?(Hash) ? p["name"] : p.to_s }
          puts "yes" if names.include?(ARGV[1])
        ' "$brainiac_dir/plugins.json" "$cmd" 2>/dev/null)

        if [[ "$is_plugin" == "yes" && $cword -eq 2 ]]; then
          # Get plugin subcommands via its CLI module
          local subcmds
          subcmds=$(ruby -rjson -e '
            brainiac_dir = ENV["BRAINIAC_DIR"] || File.join(Dir.home, ".brainiac")
            config = JSON.parse(File.read(File.join(brainiac_dir, "plugins.json")))
            entry = (config["plugins"] || []).find { |p| (p.is_a?(Hash) ? p["name"] : p.to_s) == ARGV[0] }
            next unless entry

            module Brainiac; module Plugins; end; end

            if entry.is_a?(Hash) && entry["path"]
              $LOAD_PATH.unshift(File.join(entry["path"], "lib"))
            end

            cli_file = if entry.is_a?(Hash) && entry["path"]
                         File.join(entry["path"], "lib", "brainiac", "plugins", ARGV[0], "cli.rb")
                       end

            if cli_file && File.exist?(cli_file)
              load cli_file
              pascal = ARGV[0].split(/[-_]/).map(&:capitalize).join
              mod = Brainiac::Plugins.const_get(pascal) if Brainiac::Plugins.const_defined?(pascal)
              if mod&.respond_to?(:completions)
                puts mod.completions.join("\n")
              end
            end
          ' "$cmd" 2>/dev/null)
          COMPREPLY=($(compgen -W "$subcmds" -- "$cur"))
        fi
      fi
      ;;
  esac
}

complete -F _brainiac brainiac

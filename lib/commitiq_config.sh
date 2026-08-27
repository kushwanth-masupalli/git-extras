#!/usr/bin/env bash
#
# commitiq config management in pure Bash.
# Stores provider/model/api key in ~/.commitiq/config as key=value lines.
#

set -euo pipefail

CONFIG_DIR="$HOME/.commitiq"
CONFIG_FILE="$CONFIG_DIR/config"

load_config() {
  CFG_PROVIDER=""
  CFG_MODEL=""
  CFG_API_KEY=""
  CFG_ENDPOINT=""
  CFG_COMMAND=""
  if [ -f "$CONFIG_FILE" ]; then
    while IFS= read -r line || [ -n "$line" ]; do
      line="$(echo "$line" | sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//')"
      [[ -z "$line" || "$line" =~ ^# ]] && continue
      if [[ "$line" =~ ^([^=]+)=(.*)$ ]]; then
        key="${BASH_REMATCH[1]}"
        val="${BASH_REMATCH[2]}"
        key="$(echo "$key" | sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//')"
        val="$(echo "$val" | sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//')"
        case "$key" in
          provider) CFG_PROVIDER="$val" ;;
          model) CFG_MODEL="$val" ;;
          api_key|key|apikey) CFG_API_KEY="$val" ;;
          endpoint|endpoint_url) CFG_ENDPOINT="$val" ;;
          command|cli_cmd) CFG_COMMAND="$val" ;;
        esac
      fi
    done < "$CONFIG_FILE"
  fi
}

save_config() {
  mkdir -p "$CONFIG_DIR"
  {
    [ -n "${CFG_PROVIDER:-}" ] && echo "provider=$CFG_PROVIDER"
    [ -n "${CFG_MODEL:-}" ] && echo "model=$CFG_MODEL"
    [ -n "${CFG_API_KEY:-}" ] && echo "api_key=$CFG_API_KEY"
    [ -n "${CFG_ENDPOINT:-}" ] && echo "endpoint=$CFG_ENDPOINT"
    [ -n "${CFG_COMMAND:-}" ] && echo "command=$CFG_COMMAND"
  } > "$CONFIG_FILE"
  chmod 600 "$CONFIG_FILE" 2>/dev/null || true
}

mask() {
  local val="$1"
  if [ -z "$val" ] || [ "$val" = "none" ] || [ "$val" = "not-needed" ]; then
    echo "(not needed)"
  elif [ "${#val}" -le 8 ]; then
    printf '%.0s*' $(seq 1 "${#val}")
    echo ""
  else
    local prefix="${val:0:4}"
    local suffix="${val: -4}"
    echo "${prefix}...${suffix}"
  fi
}

check_bin_on_path() {
  local bin="$1"
  [ -z "$bin" ] && return 1

  # Fast bash builtin check
  if command -v "$bin" >/dev/null 2>&1 \
     || command -v "${bin}.exe" >/dev/null 2>&1 \
     || command -v "${bin}.cmd" >/dev/null 2>&1 \
     || command -v "${bin}.bat" >/dev/null 2>&1; then
    return 0
  fi

  # Well-known AppData / local bin paths
  if [ -f "$HOME/AppData/Local/$bin/bin/${bin}.exe" ] \
     || [ -f "$HOME/AppData/Local/$bin/bin/$bin" ] \
     || [ -f "$HOME/.local/bin/$bin" ]; then
    return 0
  fi

  # Pure bash PATH scanner (splits by : or ;)
  local path_var="${PATH:-}"
  local dir
  local save_ifs="$IFS"
  IFS=':;'
  for dir in $path_var; do
    IFS="$save_ifs"
    [ -z "$dir" ] && continue
    dir="${dir//\\\\//}"
    if [ -f "$dir/$bin" ] \
       || [ -f "$dir/${bin}.exe" ] \
       || [ -f "$dir/${bin}.cmd" ] \
       || [ -f "$dir/${bin}.bat" ]; then
      return 0
    fi
  done
  IFS="$save_ifs"

  return 1
}

validate_credentials() {
  local provider="$1"
  local api_key="$2"
  local model="$3"
  local endpoint="${4:-}"
  local cli_cmd="${5:-}"

  echo "[commitiq] validating configuration for '$provider'..." >&2

  local response=""
  local payload=""

  case "$provider" in
    anthropic)
      payload="{\"model\":\"${model}\",\"max_tokens\":1,\"messages\":[{\"role\":\"user\",\"content\":\"ping\"}]}"
      response="$(curl -s -w "\nHTTP_STATUS:%{http_code}" -X POST "https://api.anthropic.com/v1/messages" \
        -H "content-type: application/json" \
        -H "x-api-key: ${api_key}" \
        -H "anthropic-version: 2023-06-01" \
        -d "$payload")"
      ;;
    openai)
      payload="{\"model\":\"${model}\",\"max_tokens\":1,\"messages\":[{\"role\":\"user\",\"content\":\"ping\"}]}"
      response="$(curl -s -w "\nHTTP_STATUS:%{http_code}" -X POST "https://api.openai.com/v1/chat/completions" \
        -H "content-type: application/json" \
        -H "authorization: Bearer ${api_key}" \
        -d "$payload")"
      ;;
    gemini)
      payload="{\"contents\":[{\"parts\":[{\"text\":\"ping\"}]}]}"
      response="$(curl -s -w "\nHTTP_STATUS:%{http_code}" -X POST "https://generativelanguage.googleapis.com/v1beta/models/${model}:generateContent?key=${api_key}" \
        -H "content-type: application/json" \
        -d "$payload")"
      ;;
    ollama)
      local host="${endpoint:-http://localhost:11434}"
      payload="{\"model\":\"${model}\",\"prompt\":\"ping\",\"stream\":false}"
      response="$(curl -s -w "\nHTTP_STATUS:%{http_code}" -X POST "${host}/api/generate" \
        -H "content-type: application/json" \
        -d "$payload")"
      ;;
    local)
      local host="${endpoint:-http://localhost:1234/v1}"
      payload="{\"model\":\"${model}\",\"max_tokens\":1,\"messages\":[{\"role\":\"user\",\"content\":\"ping\"}]}"
      response="$(curl -s -w "\nHTTP_STATUS:%{http_code}" -X POST "${host}/chat/completions" \
        -H "content-type: application/json" \
        -H "authorization: Bearer ${api_key:-not-needed}" \
        -d "$payload")"
      ;;
    cli)
      local bin_name
      bin_name="$(echo "$cli_cmd" | awk '{print $1}')"
      if [ -z "$bin_name" ]; then
        echo "[commitiq] validation failed: no CLI command provided" >&2
        return 1
      fi

      if check_bin_on_path "$bin_name"; then
        echo "[commitiq] CLI tool '$bin_name' found on system PATH!" >&2
        return 0
      elif [ "$bin_name" = "antigravity" ] && check_bin_on_path "agy"; then
        echo "[commitiq] Antigravity CLI binary 'agy' found on system PATH!" >&2
        return 0
      elif [ "$bin_name" = "agy" ] && check_bin_on_path "antigravity"; then
        echo "[commitiq] Antigravity CLI binary 'antigravity' found on system PATH!" >&2
        return 0
      else
        echo "[commitiq] validation failed: CLI command '$bin_name' not found on PATH" >&2
        return 1
      fi
      ;;
    *)
      echo "commitiq: unknown provider '$provider'" >&2
      return 1
      ;;
  esac

  local status_code
  status_code="$(echo "$response" | grep "HTTP_STATUS:" | cut -d':' -f2)"
  local body
  body="$(echo "$response" | sed '/HTTP_STATUS:/d')"

  if [ "$status_code" -ne 200 ]; then
    echo "[commitiq] validation failed (HTTP status $status_code)" >&2
    local err_snippet
    err_snippet="$(echo "$body" | head -n 3)"
    if [ -n "$err_snippet" ]; then
      echo "$err_snippet" >&2
    fi
    return 1
  fi

  echo "[commitiq] connection validated successfully!" >&2
  return 0
}

cmd_setup() {
  load_config
  local provider=""
  local api_key=""
  local model=""
  local endpoint=""
  local cli_cmd=""
  local skip_verify=0

  while [[ $# -gt 0 ]]; do
    case "$1" in
      --provider)
        provider="$2"
        shift 2
        ;;
      --api-key)
        api_key="$2"
        shift 2
        ;;
      --model)
        model="$2"
        shift 2
        ;;
      --endpoint|--endpoint-url)
        endpoint="$2"
        shift 2
        ;;
      --command|--cli-cmd)
        cli_cmd="$2"
        shift 2
        ;;
      --skip-verify|--no-verify)
        skip_verify=1
        shift 1
        ;;
      *)
        echo "commitiq: unknown setup flag '$1'" >&2
        exit 1
        ;;
    esac
  done

  local interactive=0
  if [ -z "$provider" ] && [ -z "$api_key" ]; then
    interactive=1
  fi

  if [ -z "$provider" ]; then
    echo "commitiq setup — choose a provider:"
    echo "  1) anthropic"
    echo "  2) openai"
    echo "  3) gemini"
    echo "  4) ollama (local LLM server - no API key needed)"
    echo "  5) local (custom local endpoint, e.g. LM Studio / LocalAI)"
    echo "  6) cli (installed local CLI tool, e.g. agy / antigravity, claude, aichat, llm)"
    read -r -p "Provider [1-6]: " choice < /dev/tty || choice=""
    case "$choice" in
      1) provider="anthropic" ;;
      2) provider="openai" ;;
      3) provider="gemini" ;;
      4) provider="ollama" ;;
      5) provider="local" ;;
      6) provider="cli" ;;
      *) provider="$(echo "$choice" | tr '[:upper:]' '[:lower:]')" ;;
    esac
  fi

  case "$provider" in
    anthropic|openai|gemini|ollama|local|cli) ;;
    *)
      echo "commitiq: unknown provider '$provider' (expected anthropic, gemini, openai, ollama, local, cli)" >&2
      exit 1
      ;;
  esac

  if [ "$provider" = "ollama" ]; then
    api_key="${api_key:-none}"
    endpoint="${endpoint:-http://localhost:11434}"
  elif [ "$provider" = "local" ]; then
    api_key="${api_key:-not-needed}"
    if [ -z "$endpoint" ] && [ "$interactive" -eq 1 ]; then
      read -r -p "Local server endpoint [http://localhost:1234/v1]: " entered_ep < /dev/tty || entered_ep=""
      endpoint="${entered_ep:-http://localhost:1234/v1}"
    else
      endpoint="${endpoint:-http://localhost:1234/v1}"
    fi
  elif [ "$provider" = "cli" ]; then
    api_key="${api_key:-not-needed}"
    if [ -z "$cli_cmd" ] && [ "$interactive" -eq 1 ]; then
      local default_cmd="agy --print"
      if check_bin_on_path "agy"; then
        default_cmd="agy --print"
      elif check_bin_on_path "antigravity"; then
        default_cmd="antigravity prompt"
      elif check_bin_on_path "claude"; then
        default_cmd="claude -p"
      fi
      read -r -p "CLI Command [$default_cmd]: " entered_cmd < /dev/tty || entered_cmd=""
      cli_cmd="${entered_cmd:-$default_cmd}"
    else
      cli_cmd="${cli_cmd:-agy --print}"
    fi

    # Automatically replace 'antigravity' with 'agy' if 'antigravity' binary doesn't exist but 'agy' does
    local bin_name
    bin_name="$(echo "$cli_cmd" | awk '{print $1}')"
    if [ "$bin_name" = "antigravity" ] && ! check_bin_on_path "antigravity" && check_bin_on_path "agy"; then
      cli_cmd="agy $(echo "$cli_cmd" | cut -d' ' -f2-)"
    fi
    model="${model:-cli-tool}"
  else
    if [ -z "$api_key" ]; then
      read -r -s -p "$provider API key (input hidden): " api_key < /dev/tty || api_key=""
      echo "" >&2
    fi
    if [ -z "$api_key" ]; then
      echo "commitiq: no API key given, aborting setup" >&2
      exit 1
    fi
  fi

  if [ -z "$model" ]; then
    local default_model=""
    case "$provider" in
      anthropic) default_model="claude-3-5-sonnet-latest" ;;
      openai) default_model="gpt-4o-mini" ;;
      gemini) default_model="gemini-2.0-flash" ;;
      ollama) default_model="llama3.2" ;;
      local) default_model="local-model" ;;
      cli) default_model="cli-tool" ;;
      *) default_model="default-model" ;;
    esac

    if [ "$interactive" -eq 1 ]; then
      read -r -p "Model [$default_model]: " entered < /dev/tty || entered=""
      model="${entered:-$default_model}"
    else
      model="$default_model"
    fi
  fi

  if [ "$skip_verify" -eq 0 ]; then
    if ! validate_credentials "$provider" "$api_key" "$model" "$endpoint" "$cli_cmd"; then
      echo "commitiq: validation failed — configuration not saved." >&2
      echo "commitiq: check your configuration, or run with --skip-verify to force save." >&2
      exit 1
    fi
  fi

  CFG_PROVIDER="$provider"
  CFG_API_KEY="$api_key"
  CFG_MODEL="$model"
  CFG_ENDPOINT="$endpoint"
  CFG_COMMAND="$cli_cmd"
  save_config

  echo "commitiq: saved config to $CONFIG_FILE (provider=$provider, model=$model)"
}

cmd_get() {
  if [ $# -lt 1 ]; then
    echo "usage: git commitiq config get <provider|model|api_key|endpoint|command>" >&2
    exit 1
  fi
  load_config
  local key="$1"
  case "$key" in
    provider) echo "${CFG_PROVIDER:-"(not set)"}" ;;
    model) echo "${CFG_MODEL:-"(not set)"}" ;;
    api_key|key|apikey) mask "${CFG_API_KEY:-}" ;;
    endpoint|endpoint_url) echo "${CFG_ENDPOINT:-"(not set)"}" ;;
    command|cli_cmd) echo "${CFG_COMMAND:-"(not set)"}" ;;
    *)
      echo "commitiq: unknown config key '$key'" >&2
      exit 1
      ;;
  esac
}

cmd_set() {
  if [ $# -lt 2 ]; then
    echo "usage: git commitiq config set <key> <value>" >&2
    exit 1
  fi
  load_config
  local key="$1"
  shift
  local value="$*"

  case "$key" in
    provider)
      case "$value" in
        anthropic|openai|gemini|ollama|local|cli) ;;
        *)
          echo "commitiq: unknown provider '$value' (expected anthropic, gemini, openai, ollama, local, cli)" >&2
          exit 1
          ;;
      esac
      CFG_PROVIDER="$value"
      ;;
    model)
      CFG_MODEL="$value"
      ;;
    api_key|key|apikey)
      CFG_API_KEY="$value"
      key="api_key"
      ;;
    endpoint|endpoint_url)
      CFG_ENDPOINT="$value"
      key="endpoint"
      ;;
    command|cli_cmd)
      CFG_COMMAND="$value"
      key="command"
      ;;
    *)
      echo "commitiq: unknown config key '$key'" >&2
      exit 1
      ;;
  esac

  save_config
  echo "commitiq: $key updated"
}

cmd_unset() {
  if [ $# -lt 1 ]; then
    echo "usage: git commitiq config unset <provider|model|api_key|endpoint|command>" >&2
    exit 1
  fi
  load_config
  local key="$1"

  case "$key" in
    provider) CFG_PROVIDER="" ;;
    model) CFG_MODEL="" ;;
    api_key|key|apikey) CFG_API_KEY="" ;;
    endpoint|endpoint_url) CFG_ENDPOINT="" ;;
    command|cli_cmd) CFG_COMMAND="" ;;
    *)
      echo "commitiq: unknown config key '$key'" >&2
      exit 1
      ;;
  esac

  save_config
  echo "commitiq: $key unset"
}

cmd_list() {
  load_config
  echo "provider = ${CFG_PROVIDER:-"(not set)"}"
  echo "model    = ${CFG_MODEL:-"(not set)"}"
  echo "api_key  = $(mask "${CFG_API_KEY:-}")"
  [ -n "${CFG_ENDPOINT:-}" ] && echo "endpoint = $CFG_ENDPOINT"
  [ -n "${CFG_COMMAND:-}" ] && echo "command  = $CFG_COMMAND"
  echo "(config file: $CONFIG_FILE)"
}

main() {
  if [ $# -lt 1 ]; then
    echo "usage: git commitiq config <get|set|unset|list> ..." >&2
    exit 1
  fi
  local action="$1"
  shift
  case "$action" in
    setup) cmd_setup "$@" ;;
    get) cmd_get "$@" ;;
    set) cmd_set "$@" ;;
    unset) cmd_unset "$@" ;;
    list) cmd_list "$@" ;;
    *)
      echo "commitiq: unknown config action '$action'" >&2
      exit 1
      ;;
  esac
}

main "$@"

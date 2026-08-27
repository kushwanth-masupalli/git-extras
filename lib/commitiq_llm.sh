#!/usr/bin/env bash
#
# commitiq semantic diff summarizer in pure Bash.
# Reads a git diff from stdin, asks the LLM (Anthropic, OpenAI, Gemini,
# Ollama, local OpenAI-compatible endpoint, or a local CLI tool like
# agy/antigravity, Claude Code, aichat, llm) for a structured JSON
# summary, validates it, and prints the JSON object on stdout.
#
# The JSON schema is contract with callers (bin/git-commitiq stores it
# verbatim in a git note):
#   {
#     "type": "feat"|"fix"|"refactor"|"docs"|"chore"|"test"|"perf"|"build"|"ci"|"revert"|"style",
#     "scope": "...",
#     "summary": "...",
#     "description": "...",
#     "changed_files": ["..."],
#     "breaking_change": true|false,
#     "review_notes": "..."
#   }
#

set -euo pipefail

CONFIG_FILE="$HOME/.commitiq/config"

STRICT_RETRY=0

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

resolve_credentials() {
  load_config
  local forced="${COMMITIQ_PROVIDER:-}"
  forced="$(echo "$forced" | tr '[:upper:]' '[:lower:]')"

  if [ -n "$forced" ]; then
    PROVIDER="$forced"
  elif [ -n "${ANTHROPIC_API_KEY:-}" ]; then
    PROVIDER="anthropic"
  elif [ -n "${OPENAI_API_KEY:-}" ]; then
    PROVIDER="openai"
  elif [ -n "${GEMINI_API_KEY:-}" ] || [ -n "${GOOGLE_API_KEY:-}" ]; then
    PROVIDER="gemini"
  elif [ -n "${CFG_PROVIDER:-}" ]; then
    PROVIDER="$CFG_PROVIDER"
  else
    # Auto-detect local CLI tools or local servers
    if check_bin_on_path "agy"; then
      PROVIDER="cli"
      COMMAND="agy --print"
    elif check_bin_on_path "antigravity"; then
      PROVIDER="cli"
      COMMAND="antigravity prompt"
    elif check_bin_on_path "claude"; then
      PROVIDER="cli"
      COMMAND="claude -p"
    elif check_bin_on_path "aichat"; then
      PROVIDER="cli"
      COMMAND="aichat"
    elif check_bin_on_path "llm"; then
      PROVIDER="cli"
      COMMAND="llm"
    elif curl -s -m 1 "http://localhost:11434/api/tags" >/dev/null 2>&1; then
      PROVIDER="ollama"
    else
      PROVIDER=""
      API_KEY=""
      MODEL=""
      ENDPOINT=""
      COMMAND=""
      return 0
    fi
  fi

  case "$PROVIDER" in
    anthropic)
      API_KEY="${ANTHROPIC_API_KEY:-${CFG_API_KEY:-}}"
      MODEL="${COMMITIQ_ANTHROPIC_MODEL:-${CFG_MODEL:-claude-3-5-sonnet-latest}}"
      ENDPOINT=""
      COMMAND=""
      ;;
    openai)
      API_KEY="${OPENAI_API_KEY:-${CFG_API_KEY:-}}"
      MODEL="${COMMITIQ_OPENAI_MODEL:-${CFG_MODEL:-gpt-4o-mini}}"
      ENDPOINT=""
      COMMAND=""
      ;;
    gemini)
      API_KEY="${GEMINI_API_KEY:-${GOOGLE_API_KEY:-${CFG_API_KEY:-}}}"
      MODEL="${COMMITIQ_GEMINI_MODEL:-${CFG_MODEL:-gemini-2.0-flash}}"
      ENDPOINT=""
      COMMAND=""
      ;;
    ollama)
      API_KEY="none"
      MODEL="${CFG_MODEL:-llama3.2}"
      ENDPOINT="${CFG_ENDPOINT:-http://localhost:11434}"
      COMMAND=""
      ;;
    local)
      API_KEY="${CFG_API_KEY:-not-needed}"
      MODEL="${CFG_MODEL:-local-model}"
      ENDPOINT="${CFG_ENDPOINT:-http://localhost:1234/v1}"
      COMMAND=""
      ;;
    cli)
      API_KEY="none"
      MODEL="${CFG_MODEL:-cli-tool}"
      ENDPOINT=""
      COMMAND="${CFG_COMMAND:-${COMMAND:-agy --print}}"
      ;;
    *)
      API_KEY=""
      MODEL=""
      ENDPOINT=""
      COMMAND=""
      ;;
  esac
}

json_escape() {
  awk '
    BEGIN { first = 1 }
    {
      gsub(/\\/, "\\\\")
      gsub(/"/, "\\\"")
      gsub(/\r/, "")
      gsub(/\t/, "\\t")
      gsub(/\f/, "\\f")
      gsub(/\b/, "\\b")
      if (!first) { printf "\\n" }
      printf "%s", $0
      first = 0
    }
  '
}

extract_json_text() {
  local target_field="$1"
  awk -v field="$target_field" '
    BEGIN {
      regex = "\"" field "\"[[:space:]]*:[[:space:]]*\""
    }
    {
      if (match($0, regex)) {
        start = RSTART + RLENGTH
        rest = substr($0, start)
        val = ""
        escaped = 0
        for (i = 1; i <= length(rest); i++) {
          c = substr(rest, i, 1)
          if (escaped) {
            if (c == "n") val = val "\n"
            else if (c == "r") val = val "\r"
            else if (c == "t") val = val "\t"
            else val = val c
            escaped = 0
          } else if (c == "\\") {
            escaped = 1
          } else if (c == "\"") {
            break
          } else {
            val = val c
          }
        }
        print val
        exit
      }
    }
  '
}

# Shared prompt header: expert role, exact schema, field rules, and a
# worked example. Kept in one place so the initial prompt, the strict
# retry prompt, and the CLI path all use identical instructions.
read -r -d '' PROMPT_INTRO <<'COMMITIQ_PROMPT_EOF' || true
You are an expert software engineer writing a Conventional Commit summary for a changelog. You are given a git diff. Reply with ONLY a single valid JSON object and nothing else - no markdown, no code fences, no prose before or after.

EXACT OUTPUT SCHEMA (all keys required):
{"type":"feat|fix|refactor|docs|chore|test|perf|build|ci|revert|style","scope":"optional short scope or empty string","summary":"imperative summary under 60 characters","description":"2-4 sentences on what changed and why it matters","changed_files":["exact file paths from the diff"],"breaking_change":true|false,"review_notes":"anything a reviewer must know, or empty string"}

RULES:
1. Output exactly one JSON object. No markdown fences, no "Here is", no trailing commentary.
2. type: pick the single best conventional-commit type:
   - feat: new user-facing feature or capability
   - fix: a bug fix
   - perf: a measurable performance improvement
   - docs: documentation-only change
   - refactor: internal change that fixes no bug and adds no feature
   - style: formatting, whitespace, or lint-only changes
   - test: tests-only change
   - build: build system or dependency changes
   - ci: CI configuration changes
   - chore: maintenance, tooling, or dependency updates
   - revert: reverts an earlier change
3. scope: short noun for the affected area (e.g. "auth", "parser"), or "" when none.
4. summary: imperative mood, present tense, under 60 characters, no trailing period. Do not start with "Updated" or "Changed" - start with a verb such as Add, Fix, Refactor, Remove, Improve, Handle, Migrate. Say WHAT, not HOW.
5. description: 2-4 sentences. What changed and why it matters; name the exact files or areas touched, using the paths exactly as they appear in the diff.
6. changed_files: the exact file paths from the diff (full paths as git prints them). Never invent or rename files.
7. breaking_change: true only if existing callers or behavior would break; otherwise false.
8. review_notes: anything a reviewer must know (risks, follow-ups, related work), or "".
9. The object must be valid JSON that jq can parse: escape quotes and backslashes, no trailing commas, no single quotes as string delimiters.

WORKED EXAMPLE

Diff:
--- a/src/login.js
+++ b/src/login.js
@@ -12,6 +12,8 @@
-  if (token.expired) { throw new Error("expired"); }
+  if (token.expired) { return { error: "session expired" }; }
+  await refreshSession(token);

Correct response:
{"type":"fix","scope":"auth","summary":"Handle expired session tokens gracefully","description":"Login no longer throws when a session token has expired; it now returns a clear error and refreshes the session. Touches src/login.js.","changed_files":["src/login.js"],"breaking_change":false,"review_notes":"Callers that caught the old exception should handle the new error return value."}

The diff to summarize follows:
COMMITIQ_PROMPT_EOF

build_prompt() {
  local diff_text="$1"
  if [ "$STRICT_RETRY" = "1" ]; then
    printf '%s\n\nYour previous response was not a valid JSON object. Respond AGAIN with ONLY a single JSON object matching the EXACT OUTPUT SCHEMA above - all keys present, valid JSON, no markdown.\n\n%s' "$PROMPT_INTRO" "$diff_text"
  else
    printf '%s\n\n%s' "$PROMPT_INTRO" "$diff_text"
  fi
}

# Keeps only the JSON object: strips markdown fences and any prose the
# model may have wrapped around the object, then normalizes to one line.
normalize_json() {
  local raw="$1"
  [ -z "$raw" ] && return 1
  # strip CR (Windows CLI tools may emit CRLF) - breaks jq and strict parsers
  raw="$(printf '%s' "$raw" | tr -d '\r')"
  # strip ```json / ``` fences
  raw="$(printf '%s' "$raw" | sed -e 's/^[[:space:]]*```[a-zA-Z0-9]*//' -e 's/```[[:space:]]*$//')"
  # keep only from the first '{' to the last '}'
  raw="$(printf '%s' "$raw" | awk '
    { buf = buf $0 "\n" }
    END {
      f = index(buf, "{")
      l = 0
      for (i = length(buf); i >= 1; i--) {
        if (substr(buf, i, 1) == "}") { l = i; break }
      }
      if (f > 0 && l > f) print substr(buf, f, l - f + 1)
    }
  ')"
  printf '%s' "$raw"
}

is_valid_json() {
  local s="$1"
  [ -z "$s" ] && return 1
  case "$s" in
    "{"*"}" ) ;;
    *) return 1 ;;
  esac
  if command -v jq >/dev/null 2>&1; then
    printf '%s' "$s" | jq -e '
      type == "object"
      and (["feat", "fix", "refactor", "docs", "chore", "test", "perf", "build", "ci", "revert", "style"] | index(.type) != null)
      and (has("summary") and has("description") and has("changed_files") and has("breaking_change") and has("review_notes"))
      and (.changed_files | type == "array")
    ' >/dev/null 2>&1
  else
    printf '%s' "$s" | grep -q '"type"' || return 1
    printf '%s' "$s" | grep -q '"summary"' || return 1
    printf '%s' "$s" | grep -Eq '"(feat|fix|refactor|docs|chore|test|perf|build|ci|revert|style)"' || return 1
  fi
}

call_anthropic() {
  local raw_diff="$1"
  local api_key="$2"
  local model="$3"

  local prompt prompt_escaped payload response status_code body
  prompt="$(build_prompt "$raw_diff")"
  prompt_escaped="$(printf '%s' "$prompt" | json_escape)"
  payload="{\"model\":\"${model}\",\"max_tokens\":500,\"messages\":[{\"role\":\"user\",\"content\":\"${prompt_escaped}\"}]}"

  response="$(curl -s -w "\nHTTP_STATUS:%{http_code}" -X POST "https://api.anthropic.com/v1/messages" \
    -H "content-type: application/json" \
    -H "x-api-key: ${api_key}" \
    -H "anthropic-version: 2023-06-01" \
    -d "$payload")"

  status_code="$(echo "$response" | grep "HTTP_STATUS:" | cut -d':' -f2)"
  body="$(echo "$response" | sed '/HTTP_STATUS:/d')"

  if [ "$status_code" -ne 200 ]; then
    echo "commitiq: anthropic API error $status_code: $(echo "$body" | head -n 5)" >&2
    exit 1
  fi

  echo "$body" | extract_json_text "text"
}

call_openai() {
  local raw_diff="$1"
  local api_key="$2"
  local model="$3"

  local prompt prompt_escaped payload response status_code body
  prompt="$(build_prompt "$raw_diff")"
  prompt_escaped="$(printf '%s' "$prompt" | json_escape)"
  payload="{\"model\":\"${model}\",\"max_tokens\":500,\"messages\":[{\"role\":\"user\",\"content\":\"${prompt_escaped}\"}]}"

  response="$(curl -s -w "\nHTTP_STATUS:%{http_code}" -X POST "https://api.openai.com/v1/chat/completions" \
    -H "content-type: application/json" \
    -H "authorization: Bearer ${api_key}" \
    -d "$payload")"

  status_code="$(echo "$response" | grep "HTTP_STATUS:" | cut -d':' -f2)"
  body="$(echo "$response" | sed '/HTTP_STATUS:/d')"

  if [ "$status_code" -ne 200 ]; then
    echo "commitiq: openai API error $status_code: $(echo "$body" | head -n 5)" >&2
    exit 1
  fi

  echo "$body" | extract_json_text "content"
}

call_gemini() {
  local raw_diff="$1"
  local api_key="$2"
  local model="$3"

  local prompt prompt_escaped payload response status_code body
  prompt="$(build_prompt "$raw_diff")"
  prompt_escaped="$(printf '%s' "$prompt" | json_escape)"
  payload="{\"contents\":[{\"parts\":[{\"text\":\"${prompt_escaped}\"}]}]}"

  response="$(curl -s -w "\nHTTP_STATUS:%{http_code}" -X POST "https://generativelanguage.googleapis.com/v1beta/models/${model}:generateContent?key=${api_key}" \
    -H "content-type: application/json" \
    -d "$payload")"

  status_code="$(echo "$response" | grep "HTTP_STATUS:" | cut -d':' -f2)"
  body="$(echo "$response" | sed '/HTTP_STATUS:/d')"

  if [ "$status_code" -ne 200 ]; then
    echo "commitiq: gemini API error $status_code: $(echo "$body" | head -n 5)" >&2
    exit 1
  fi

  echo "$body" | extract_json_text "text"
}

call_ollama() {
  local raw_diff="$1"
  local model="$2"
  local endpoint="${3:-http://localhost:11434}"

  local prompt prompt_escaped payload response status_code body
  prompt="$(build_prompt "$raw_diff")"
  prompt_escaped="$(printf '%s' "$prompt" | json_escape)"
  payload="{\"model\":\"${model}\",\"prompt\":\"${prompt_escaped}\",\"stream\":false}"

  response="$(curl -s -w "\nHTTP_STATUS:%{http_code}" -X POST "${endpoint}/api/generate" \
    -H "content-type: application/json" \
    -d "$payload")"

  status_code="$(echo "$response" | grep "HTTP_STATUS:" | cut -d':' -f2)"
  body="$(echo "$response" | sed '/HTTP_STATUS:/d')"

  if [ "$status_code" -ne 200 ]; then
    echo "commitiq: ollama API error $status_code: $(echo "$body" | head -n 5)" >&2
    exit 1
  fi

  echo "$body" | extract_json_text "response"
}

call_local() {
  local raw_diff="$1"
  local api_key="$2"
  local model="$3"
  local endpoint="${4:-http://localhost:1234/v1}"

  local prompt prompt_escaped payload response status_code body
  prompt="$(build_prompt "$raw_diff")"
  prompt_escaped="$(printf '%s' "$prompt" | json_escape)"
  payload="{\"model\":\"${model}\",\"max_tokens\":500,\"messages\":[{\"role\":\"user\",\"content\":\"${prompt_escaped}\"}]}"

  response="$(curl -s -w "\nHTTP_STATUS:%{http_code}" -X POST "${endpoint}/chat/completions" \
    -H "content-type: application/json" \
    -H "authorization: Bearer ${api_key:-not-needed}" \
    -d "$payload")"

  status_code="$(echo "$response" | grep "HTTP_STATUS:" | cut -d':' -f2)"
  body="$(echo "$response" | sed '/HTTP_STATUS:/d')"

  if [ "$status_code" -ne 200 ]; then
    echo "commitiq: local API error $status_code: $(echo "$body" | head -n 5)" >&2
    exit 1
  fi

  echo "$body" | extract_json_text "content"
}

call_cli() {
  local raw_diff="$1"
  local cli_cmd="${2:-agy --print}"

  local bin_name
  bin_name="$(echo "$cli_cmd" | awk '{print $1}')"

  # Alias 'antigravity' to 'agy' if 'antigravity' doesn't exist but 'agy' does
  if [ "$bin_name" = "antigravity" ] && ! check_bin_on_path "antigravity" && check_bin_on_path "agy"; then
    cli_cmd="agy --print"
  fi

  local prompt err_tmp res status
  prompt="$(build_prompt "$raw_diff")"
  err_tmp="$(mktemp 2>/dev/null || echo "/tmp/commitiq_cli_err_$$")"

  res="$(printf '%s\n' "$prompt" | eval "$cli_cmd" 2>"$err_tmp")" || status=$?
  status="${status:-0}"

  if [ "$status" -ne 0 ] || [ -z "$res" ]; then
    if [ -s "$err_tmp" ]; then
      echo "commitiq: CLI command '$cli_cmd' failed (exit code $status):" >&2
      cat "$err_tmp" >&2
    fi
  fi
  rm -f "$err_tmp" 2>/dev/null || true
  printf '%s' "$res"
}

main() {
  PROVIDER=""
  API_KEY=""
  MODEL=""
  ENDPOINT=""
  COMMAND=""
  resolve_credentials

  if [ -z "$PROVIDER" ]; then
    echo "commitiq: no provider configured and no local CLI tool / LLM found. Run 'git commitiq setup'." >&2
    exit 1
  fi

  local raw_diff
  raw_diff="$(cat)"

  if [ -z "$(echo "$raw_diff" | tr -d '[:space:]')" ]; then
    echo "commitiq: empty diff, nothing to summarize" >&2
    exit 1
  fi

  STRICT_RETRY=0
  local attempt=1
  while [ "$attempt" -le 2 ]; do
    local summary=""
    if [ "$PROVIDER" = "cli" ]; then
      summary="$(call_cli "$raw_diff" "$COMMAND")" || summary=""
    else
      case "$PROVIDER" in
        anthropic) summary="$(call_anthropic "$raw_diff" "$API_KEY" "$MODEL")" || summary="" ;;
        openai)    summary="$(call_openai "$raw_diff" "$API_KEY" "$MODEL")" || summary="" ;;
        gemini)    summary="$(call_gemini "$raw_diff" "$API_KEY" "$MODEL")" || summary="" ;;
        ollama)    summary="$(call_ollama "$raw_diff" "$MODEL" "$ENDPOINT")" || summary="" ;;
        local)     summary="$(call_local "$raw_diff" "$API_KEY" "$MODEL" "$ENDPOINT")" || summary="" ;;
        *)
          echo "commitiq: unknown provider '$PROVIDER'" >&2
          exit 1
          ;;
      esac
    fi

    if [ -z "$summary" ]; then
      # empty output = transport/API error (or empty model response) -
      # retrying would just repeat the same failing call, so stop here.
      break
    fi

    summary="$(normalize_json "$summary" || true)"
    if is_valid_json "$summary"; then
      echo "$summary"
      exit 0
    fi

    # Non-empty but not valid JSON (model returned prose) - retry once
    # with stricter instructions.
    if [ "$attempt" -eq 1 ]; then
      STRICT_RETRY=1
      echo "commitiq: $PROVIDER response was not valid JSON - retrying once with stricter instructions" >&2
    fi
    attempt=$((attempt + 1))
  done

  echo "commitiq: $PROVIDER did not produce a valid JSON summary" >&2
  exit 1
}

main "$@"

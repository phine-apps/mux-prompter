#!/usr/bin/env bash
# Mux Prompter - Fuzzy-pick and inject context-aware prompts into Herdr & tmux panes
# SPDX-License-Identifier: MIT

## Absolute path of this script to allow self-invocation after directory changes
SCRIPT_PATH="$(cd "$(dirname "$0")" && pwd)/$(basename "$0")"

# Multiplexer CLI paths & backend configuration
HERDR_BIN="${HERDR_BIN_PATH:-herdr}"
TMUX_BIN="${TMUX_BIN_PATH:-tmux}"
ZELLIJ_BIN="${ZELLIJ_BIN_PATH:-zellij}"
MUX_BACKEND_CONF="${MUX_BACKEND:-auto}"

# Export standard installation paths as fallback to ensure dependencies are found in tmux popups
export PATH="$PATH:/opt/homebrew/bin:/usr/local/bin"

# Check dependencies
if ! command -v jq &> /dev/null; then
  echo "Error: 'jq' is required to run this plugin." >&2
  if [ -t 0 ]; then
    read -r -p "Press Enter to exit..."
  fi
  exit 1
fi

if ! command -v fzf &> /dev/null; then
  echo "Error: 'fzf' is required to run this plugin." >&2
  if [ -t 0 ]; then
    read -r -p "Press Enter to exit..."
  fi
  exit 1
fi

# Execute git safely without pagers
safe_git() {
  PAGER="cat" git --no-pager "$@"
}

# Replace target string with replacement string in content
# Handles special characters safely
safe_replace() {
  local content="$1"
  local target="$2"
  local replacement="$3"
  
  if command -v python3 &>/dev/null; then
    printf '%s' "$content" | python3 -c "import sys; print(sys.stdin.read().replace(sys.argv[1], sys.argv[2]), end='')" "$target" "$replacement"
  else
    # Fallback to awk using ENVIRON to prevent -v escape sequence mangling and literal index/substr replacement
    printf '%s' "$content" | TARGET="$target" REPLACEMENT="$replacement" awk '
      BEGIN {
        content = ""
      }
      {
        content = (NR == 1) ? $0 : content "\n" $0
      }
      END {
        t = ENVIRON["TARGET"]
        r = ENVIRON["REPLACEMENT"]
        if (t == "") {
          printf "%s", content
          exit
        }
        len_t = length(t)
        out = ""
        while ((idx = index(content, t)) > 0) {
          out = out substr(content, 1, idx - 1) r
          content = substr(content, idx + len_t)
        }
        out = out content
        printf "%s", out
      }
    '
  fi
}

# Detect active multiplexer backend (herdr, tmux, or zellij)
detect_backend() {
  case "$MUX_BACKEND_CONF" in
    tmux|herdr|zellij)
      echo "$MUX_BACKEND_CONF"
      return 0
      ;;
  esac

  # Auto-detection based on environment variables and active CLI responsiveness
  if [ -n "$TMUX" ]; then
    echo "tmux"
  elif [ -n "$ZELLIJ" ] || [ -n "$ZELLIJ_SESSION_NAME" ]; then
    echo "zellij"
  elif [ -n "$HERDR_PLUGIN_CONTEXT_JSON" ]; then
    echo "herdr"
  elif command -v "$TMUX_BIN" &>/dev/null && "$TMUX_BIN" info &>/dev/null; then
    echo "tmux"
  elif command -v "$HERDR_BIN" &>/dev/null; then
    echo "herdr"
  elif command -v "$TMUX_BIN" &>/dev/null; then
    echo "tmux"
  elif command -v "$ZELLIJ_BIN" &>/dev/null; then
    echo "zellij"
  else
    echo "herdr"
  fi
}

CURRENT_BACKEND=$(detect_backend)

# Invoke `zellij action`, scoping to $ZELLIJ_SESSION_NAME when set
zellij_action() {
  if [ -n "$ZELLIJ_SESSION_NAME" ]; then
    "$ZELLIJ_BIN" --session "$ZELLIJ_SESSION_NAME" action "$@"
  else
    "$ZELLIJ_BIN" action "$@"
  fi
}

# Normalize a Zellij pane identifier (bare integer or terminal_<id>) to terminal_<id>
zellij_normalize_pane_id() {
  local pid="$1"
  if [[ "$pid" =~ ^[0-9]+$ ]]; then
    echo "terminal_${pid}"
  else
    echo "$pid"
  fi
}

# Abstracted Multiplexer Operations

mux_get_target_pane_id() {
  local context_json="${1:-$HERDR_PLUGIN_CONTEXT_JSON}"
  if [ "$CURRENT_BACKEND" = "tmux" ]; then
    if [ -n "$PROMPTER_TARGET_PANE" ] && [[ "$PROMPTER_TARGET_PANE" != \#\{* ]]; then
      echo "$PROMPTER_TARGET_PANE"
    elif [ -n "$PROMPTER_CALLER_PANE" ] && [[ "$PROMPTER_CALLER_PANE" != \#\{* ]]; then
      echo "$PROMPTER_CALLER_PANE"
    elif [ -n "$TMUX_PANE" ]; then
      echo "$TMUX_PANE"
    elif command -v "$TMUX_BIN" &>/dev/null; then
      local pid
      pid=$("$TMUX_BIN" display-message -p '#{pane_id}' 2>/dev/null)
      echo "${pid:-current}"
    else
      echo "current"
    fi
  elif [ "$CURRENT_BACKEND" = "zellij" ]; then
    if [ -n "$PROMPTER_TARGET_PANE" ]; then
      zellij_normalize_pane_id "$PROMPTER_TARGET_PANE"
    elif [ -n "$PROMPTER_CALLER_PANE" ]; then
      zellij_normalize_pane_id "$PROMPTER_CALLER_PANE"
    elif command -v "$ZELLIJ_BIN" &>/dev/null && command -v jq &>/dev/null; then
      local tabs_json panes_json self_num="" pid=""
      [ -n "$ZELLIJ_PANE_ID" ] && self_num="${ZELLIJ_PANE_ID#terminal_}"
      tabs_json=$(zellij_action list-tabs --all --json 2>/dev/null)
      panes_json=$(zellij_action list-panes --all --json 2>/dev/null)
      if [ -n "$tabs_json" ] && [ -n "$panes_json" ]; then
        pid=$(printf '%s' "$panes_json" | jq -r --argjson tabs "$tabs_json" --arg self "$self_num" '
          ([$tabs[] | select(.active == true) | .tab_id][0] // null) as $active_tab |
          [
            .[] |
            select(.is_plugin == false) |
            select($self == "" or (.id | tostring) != $self) |
            select($active_tab == null or .tab_id == $active_tab)
          ] as $candidates |
          (
            [$candidates[] | select(.is_focused == true and .is_floating == false)] +
            [$candidates[] | select(.is_focused == true)] +
            [$candidates[] | select(.is_floating == false)] +
            $candidates
          )[0].id // empty |
          if . != null and . != "" then "terminal_\(.)" else empty end
        ' 2>/dev/null)
      fi
      if [ -n "$pid" ]; then
        echo "$pid"
      elif [ -n "$ZELLIJ_PANE_ID" ]; then
        zellij_normalize_pane_id "$ZELLIJ_PANE_ID"
      else
        echo "current"
      fi
    elif [ -n "$ZELLIJ_PANE_ID" ]; then
      zellij_normalize_pane_id "$ZELLIJ_PANE_ID"
    else
      echo "current"
    fi
  else
    local pid=""
    if [ -n "$context_json" ]; then
      pid=$(printf '%s' "$context_json" | jq -r '.focused_pane_id // .focused_pane.id // empty' 2>/dev/null)
    fi
    echo "${pid:-current}"
  fi
}

mux_get_workspace_cwd() {
  local context_json="${1:-$HERDR_PLUGIN_CONTEXT_JSON}"
  if [ "$CURRENT_BACKEND" = "tmux" ]; then
    if command -v "$TMUX_BIN" &>/dev/null; then
      local pid cwd target_opt=()
      pid=$(mux_get_target_pane_id "$context_json")
      if [ -n "$pid" ] && [ "$pid" != "current" ]; then
        target_opt=(-t "$pid")
      fi
      cwd=$("$TMUX_BIN" display-message "${target_opt[@]}" -p '#{pane_current_path}' 2>/dev/null)
      echo "${cwd:-$PWD}"
    else
      echo "$PWD"
    fi
  elif [ "$CURRENT_BACKEND" = "zellij" ]; then
    local cwd=""
    if command -v "$ZELLIJ_BIN" &>/dev/null && command -v jq &>/dev/null; then
      local pid num_id panes_json
      pid=$(mux_get_target_pane_id "$context_json")
      num_id="${pid#terminal_}"
      if [[ "$num_id" =~ ^[0-9]+$ ]]; then
        panes_json=$(zellij_action list-panes --all --json 2>/dev/null)
        if [ -n "$panes_json" ]; then
          cwd=$(printf '%s' "$panes_json" | jq -r --argjson id "$num_id" '[.[] | select(.is_plugin == false and .id == $id) | .pane_cwd // empty][0] // empty' 2>/dev/null)
        fi
      fi
    fi
    echo "${cwd:-$PWD}"
  else
    local cwd=""
    if [ -n "$context_json" ]; then
      cwd=$(printf '%s' "$context_json" | jq -r '.workspace_cwd // .workspace.cwd // empty' 2>/dev/null)
    fi
    echo "${cwd:-$PWD}"
  fi
}

mux_get_selected_text() {
  local context_json="${1:-$HERDR_PLUGIN_CONTEXT_JSON}"
  local sel=""

  if [ "$CURRENT_BACKEND" = "herdr" ]; then
    # For herdr, prioritize editor selection context_json over OS clipboard to prevent regression
    if [ -n "$context_json" ]; then
      sel=$(printf '%s' "$context_json" | jq -r '.selected_text // .selected.text // .selected // empty' 2>/dev/null)
    fi
    if [ -z "$sel" ]; then
      sel=$(get_clipboard_text)
    fi
  else
    # For tmux/zellij, prioritize OS clipboard over show-buffer to prevent inserting stale buffer history
    sel=$(get_clipboard_text)
    if [ -z "$sel" ] && [ "$CURRENT_BACKEND" = "tmux" ] && command -v "$TMUX_BIN" &>/dev/null; then
      sel=$("$TMUX_BIN" show-buffer 2>/dev/null)
    fi
  fi
  echo "$sel"
}

mux_read_pane_logs() {
  local pane_id="$1"
  local lines="${2:-100}"
  if [ "$CURRENT_BACKEND" = "tmux" ]; then
    local target_opt=()
    if [ -n "$pane_id" ] && [ "$pane_id" != "current" ]; then
      target_opt=(-t "$pane_id")
    fi
    "$TMUX_BIN" capture-pane "${target_opt[@]}" -p -S -"$lines" 2>/dev/null
  elif [ "$CURRENT_BACKEND" = "zellij" ]; then
    local pane_opt=()
    if [ -n "$pane_id" ] && [ "$pane_id" != "current" ]; then
      pane_opt=(--pane-id "$(zellij_normalize_pane_id "$pane_id")")
    fi
    zellij_action dump-screen "${pane_opt[@]}" --full 2>/dev/null | tail -n "$lines"
  else
    if [ "$pane_id" != "current" ]; then
      "$HERDR_BIN" pane read "$pane_id" --lines "$lines" 2>/dev/null
    fi
  fi
}

mux_list_panes() {
  if [ "$CURRENT_BACKEND" = "tmux" ]; then
    if command -v "$TMUX_BIN" &>/dev/null; then
      local exclude_pane=""
      if [ -n "$PROMPTER_CALLER_PANE" ] && [ -n "$TMUX_PANE" ] && [ "$PROMPTER_CALLER_PANE" != "$TMUX_PANE" ]; then
        exclude_pane="$TMUX_PANE"
      fi
      "$TMUX_BIN" list-panes -s -F '#{window_index}.#{pane_index} | #{pane_id} (#{pane_current_path})' 2>/dev/null | awk -v exclude="$exclude_pane" '
        {
          if (exclude != "") {
            split($0, parts, "|")
            gsub(/^[ \t]+|[ \t]+$/, "", parts[2])
            split(parts[2], pane_info, " ")
            if (pane_info[1] == exclude) {
              next
            }
          }
          print $0
        }
      ' | sed 's/^[[:space:]]*//'
    fi
  elif [ "$CURRENT_BACKEND" = "zellij" ]; then
    if command -v "$ZELLIJ_BIN" &>/dev/null && command -v jq &>/dev/null; then
      local panes_json
      panes_json=$(zellij_action list-panes --all --json 2>/dev/null)
      if [ -n "$panes_json" ]; then
        local self_num=""
        [ -n "$ZELLIJ_PANE_ID" ] && self_num="${ZELLIJ_PANE_ID#terminal_}"
        printf '%s' "$panes_json" | jq -r --arg self "$self_num" '
          [.[] | select(.is_plugin == false) | select($self == "" or (.id | tostring) != $self)]
          | sort_by(.tab_position, .id)
          | .[]
          | "\(.tab_name // ("Tab " + (.tab_position | tostring))) | terminal_\(.id)\(if .title and .title != "" then " (\(.title))" else "" end)\(if .pane_cwd and .pane_cwd != "" then " (\(.pane_cwd))" else "" end)"
        ' 2>/dev/null
      fi
    fi
  else
    local panes_json
    panes_json=$("$HERDR_BIN" pane list 2>/dev/null)
    if [ -n "$panes_json" ]; then
      local tabs_json
      tabs_json=$("$HERDR_BIN" tab list 2>/dev/null || echo "{}")
      echo "$panes_json" | jq -r --argjson tabs_obj "$tabs_json" '
        [.result.panes[] |
        . as $pane |
        (($tabs_obj.result.tabs[]? | select(.tab_id == $pane.tab_id)) // {}) as $tab |
        {
          tab_num: ($tab.number // 999),
          pane_id: $pane.pane_id,
          line: "Tab \($tab.label // $tab.number // "??") | \($pane.pane_id)\(if $pane.label and $pane.label != "" and $pane.label != $pane.pane_id then " (\($pane.label))" else "" end) (\($pane.cwd))"
        }] | sort_by(.tab_num, .pane_id)[].line
      ' 2>/dev/null
    fi
  fi
}

mux_send_text() {
  local target_pid="$1"
  local text="$2"
  if [ "$CURRENT_BACKEND" = "tmux" ]; then
    local target_opt=()
    if [ -n "$target_pid" ] && [ "$target_pid" != "current" ]; then
      target_opt=(-t "$target_pid")
    fi
    local same_tty=false
    if [ -n "$TMUX_PANE" ] && [ "$target_pid" = "$TMUX_PANE" ] && [ -t 1 ]; then
      local current_tty pane_tty
      current_tty=$(tty 2>/dev/null || true)
      pane_tty=$("$TMUX_BIN" display-message -p -t "$TMUX_PANE" '#{pane_tty}' 2>/dev/null || true)
      if [ -z "$pane_tty" ] || [ -z "$current_tty" ] || [ "$current_tty" = "$pane_tty" ]; then
        same_tty=true
      fi
    fi
    if [ "$same_tty" = true ]; then
      (trap '' HUP; sleep 0.05 && "$TMUX_BIN" send-keys "${target_opt[@]}" -l -- "$text") &>/dev/null &
    else
      "$TMUX_BIN" send-keys "${target_opt[@]}" -l -- "$text" 2>/dev/null
    fi
  elif [ "$CURRENT_BACKEND" = "zellij" ]; then
    local pane_opt=()
    local norm_pid=""
    if [ -n "$target_pid" ] && [ "$target_pid" != "current" ]; then
      norm_pid=$(zellij_normalize_pane_id "$target_pid")
      pane_opt=(--pane-id "$norm_pid")
    fi
    local self_norm=""
    [ -n "$ZELLIJ_PANE_ID" ] && self_norm=$(zellij_normalize_pane_id "$ZELLIJ_PANE_ID")
    if [ -n "$self_norm" ] && [ "$norm_pid" = "$self_norm" ] && [ -t 1 ]; then
      (trap '' HUP; sleep 0.05 && zellij_action paste "${pane_opt[@]}" -- "$text") &>/dev/null &
    else
      zellij_action paste "${pane_opt[@]}" -- "$text" 2>/dev/null
    fi
  else
    if [ "$target_pid" != "current" ]; then
      "$HERDR_BIN" pane send-text "$target_pid" "$text" 2>/dev/null
    fi
  fi
}

mux_run_command() {
  local target_pid="$1"
  local text="$2"
  if [ "$CURRENT_BACKEND" = "tmux" ]; then
    local target_opt=()
    if [ -n "$target_pid" ] && [ "$target_pid" != "current" ]; then
      target_opt=(-t "$target_pid")
    fi
    "$TMUX_BIN" send-keys "${target_opt[@]}" -l -- "$text" 2>/dev/null
    "$TMUX_BIN" send-keys "${target_opt[@]}" Enter 2>/dev/null
  elif [ "$CURRENT_BACKEND" = "zellij" ]; then
    local pane_opt=()
    if [ -n "$target_pid" ] && [ "$target_pid" != "current" ]; then
      pane_opt=(--pane-id "$(zellij_normalize_pane_id "$target_pid")")
    fi
    zellij_action paste "${pane_opt[@]}" -- "$text" 2>/dev/null
    zellij_action send-keys "${pane_opt[@]}" "Enter" 2>/dev/null
  else
    if [ "$target_pid" != "current" ]; then
      "$HERDR_BIN" pane run "$target_pid" "$text" 2>/dev/null
    fi
  fi
}

# Configuration directories
if [ -n "${HERDR_PLUGIN_CONFIG_DIR}" ]; then
  CONFIG_DIR="${HERDR_PLUGIN_CONFIG_DIR}"
else
  CONFIG_DIR="${XDG_CONFIG_HOME:-$HOME/.config}/mux-prompter"
fi
mkdir -p "$CONFIG_DIR" 2>/dev/null || true

TEMPLATES_DIR="${CONFIG_DIR}/templates"
LEGACY_TEMPLATES_FILE="${CONFIG_DIR}/templates.txt"
VARS_FILE="${TEMPLATES_DIR}/_vars.txt"
HISTORY_FILE="${CONFIG_DIR}/prompter_history.txt"

# Generate safe filename slug from title (supporting Unicode and avoiding filesystem prohibited characters)
slugify() {
  local title="$1"
  # Strip leading bang ! if present
  local clean_title="${title#!}"
  # Replace filesystem prohibited characters (/\:*?"<>|) and control chars and spaces with hyphens
  local slug
  slug=$(printf '%s' "$clean_title" | tr '[:upper:]' '[:lower:]' | sed -E 's/[/\\:*?"<>|[:cntrl:][:space:]]+/-/g' | sed -E 's/^-+|-+$//g')
  # Truncate to maximum 60 characters to prevent filesystem filename length limits (NAME_MAX)
  slug=$(printf '%s' "$slug" | cut -c1-60 | sed -E 's/-+$//')
  # Guard against slugs consisting solely of dots
  slug=$(printf '%s' "$slug" | sed -E 's/^\.+$//')
  if [ -z "$slug" ]; then
    slug="template"
  fi
  echo "$slug"
}

# Safe newline decoder: decodes literal '\n' to actual newlines, preserving escaped '\\n' as '\n' without touching other escapes
decode_literal_newlines() {
  local str="$1"
  if command -v python3 &>/dev/null; then
    printf '%s' "$str" | python3 -c 'import sys
s = sys.stdin.read()
s = s.replace(r"\\n", "\x00LITERAL_BS_N\x00")
s = s.replace(r"\n", "\n")
s = s.replace("\x00LITERAL_BS_N\x00", r"\n")
sys.stdout.write(s)
'
  else
    printf '%s' "$str" | awk '
      BEGIN { content = "" }
      { content = (NR == 1) ? $0 : content "\n" $0 }
      END {
        len = length(content)
        out = ""
        for (i = 1; i <= len; i++) {
          if (substr(content, i, 3) == "\\\\n") {
            out = out "\\n"
            i += 2
          } else if (substr(content, i, 2) == "\\n") {
            out = out "\n"
            i++
          } else {
            out = out substr(content, i, 1)
          }
        }
        printf "%s", out
      }
    '
  fi
}

# Migrate legacy templates.txt to templates/*.md and backup to templates.txt.bak
migrate_legacy_templates() {
  if [ -f "$LEGACY_TEMPLATES_FILE" ]; then
    mkdir -p "$TEMPLATES_DIR" 2>/dev/null || true
    while IFS= read -r line || [ -n "$line" ]; do
      line=$(printf '%s' "$line" | tr -d '\r')
      [[ "$line" =~ ^[[:space:]]*$ ]] && continue
      [[ "$line" =~ ^# ]] && continue
      
      # Migrate custom variable generator ($ var: cmd)
      if [[ "$line" =~ ^\$ ]]; then
        echo "$line" >> "$VARS_FILE"
        continue
      fi
      
      # Migrate template entry (Title|Body\n...)
      if [[ "$line" == *"|"* ]]; then
        local title body
        title=$(echo "$line" | cut -d'|' -f1)
        body=$(echo "$line" | cut -d'|' -f2-)
        
        local slug
        slug=$(slugify "$title")
        local target_file="${TEMPLATES_DIR}/${slug}.md"
        local count=1
        
        # Check if identical template already exists to avoid redundant duplication
        local already_migrated=false
        if [ -f "$target_file" ]; then
          local existing_body
          existing_body=$(sed '1d' "$target_file" | awk 'NF {found=1} found {print}')
          local decoded_body
          decoded_body=$(decode_literal_newlines "$body")
          if [ "$existing_body" == "$decoded_body" ]; then
            already_migrated=true
          fi
        fi
        
        if [ "$already_migrated" = false ]; then
          while [ -f "$target_file" ]; do
            count=$((count + 1))
            target_file="${TEMPLATES_DIR}/${slug}-${count}.md"
          done
          
          {
            echo "# ${title}"
            echo ""
            decode_literal_newlines "$body"
            echo ""
          } > "$target_file"
        fi
      fi
    done < "$LEGACY_TEMPLATES_FILE"
    
    # Rename legacy templates file to .bak
    mv "$LEGACY_TEMPLATES_FILE" "${LEGACY_TEMPLATES_FILE}.bak"
  fi
}

# Initialize default markdown templates in templates directory
init_default_templates() {
  mkdir -p "$TEMPLATES_DIR" 2>/dev/null || true
  
  cat << 'EOF' > "${TEMPLATES_DIR}/summarize-discussion.md"
# Summarize Discussion
Please summarize the key points of our discussion so far.
EOF

  cat << 'EOF' > "${TEMPLATES_DIR}/fix-terminal-error.md"
# Fix Terminal Error
I ran `{{last_command}}` and encountered this error:

```
{{error}}
```
Please analyze and fix this.
EOF

  cat << 'EOF' > "${TEMPLATES_DIR}/refactor-selected-code.md"
# Refactor Selected Code
Please refactor this code to improve readability and performance:

```
{{selected}}
```
EOF

  cat << 'EOF' > "${TEMPLATES_DIR}/review-git-changes.md"
# Review Git Changes
Please review the following git changes:

```
{{git_diff}}
```
EOF

  cat << 'EOF' > "${TEMPLATES_DIR}/review-branch-changes.md"
# Review Branch Changes
Please review the changes on branch `{{git_branch}}`.

Commits:
```
{{git_log:branch}}
```

Diff:
```
{{git_diff:branch}}
```
EOF

  cat << 'EOF' > "${TEMPLATES_DIR}/ask-custom-question.md"
# Ask Custom Question
{{input}}
EOF

  cat << 'EOF' > "${TEMPLATES_DIR}/cd-worktree.md"
# CD to Git Worktree
cd "{{git_worktree}}"
EOF

  cat << 'EOF' > "$VARS_FILE"
# Custom variable candidate generators ($ var_name: shell_command):
# $ branch: git branch --format="%(refname:short)"
EOF
}

# Load templates from markdown files
load_templates() {
  TEMPLATES_TITLES=()
  TEMPLATES_BODIES=()
  TEMPLATES_PATHS=()

  # Run migration if legacy templates.txt exists
  migrate_legacy_templates

  # Check if templates directory has any .md files
  local md_files=()
  if [ -d "$TEMPLATES_DIR" ]; then
    while IFS= read -r -d '' f; do
      md_files+=("$f")
    done < <(find "$TEMPLATES_DIR" -type f -name "*.md" -print0 2>/dev/null | sort -z)
  fi

  if [ "${#md_files[@]}" -eq 0 ]; then
    init_default_templates
    while IFS= read -r -d '' f; do
      md_files+=("$f")
    done < <(find "$TEMPLATES_DIR" -type f -name "*.md" -print0 2>/dev/null | sort -z)
  fi

  local raw_titles=()
  local raw_bodies=()
  local raw_paths=()

  for file in "${md_files[@]}"; do
    [ ! -f "$file" ] && continue
    local first_line title body
    first_line=$(head -n 1 "$file" | tr -d '\r')
    if [[ "$first_line" =~ ^#[[:space:]]*(.+) ]]; then
      title="${BASH_REMATCH[1]}"
      body=$(sed '1d' "$file" | tr -d '\r' | awk 'NF {found=1} found {print}')
    else
      title="$(basename "$file" .md)"
      body="$(tr -d '\r' < "$file")"
    fi
    title=$(printf '%s' "$title" | tr '\t\r' '  ' | sed -E 's/^[[:space:]]+|[[:space:]]+$//g')
    raw_titles+=("$title")
    raw_bodies+=("$body")
    raw_paths+=("$file")
  done

  # Resolve duplicate titles by appending relative path for unambiguous display & lookup
  for i in "${!raw_titles[@]}"; do
    local t="${raw_titles[$i]}"
    local p="${raw_paths[$i]}"
    local b="${raw_bodies[$i]}"
    local dup_count=0
    for other_t in "${raw_titles[@]}"; do
      if [ "$other_t" == "$t" ]; then
        dup_count=$((dup_count + 1))
      fi
    done
    local display_title="$t"
    if [ "$dup_count" -gt 1 ]; then
      local rel_p
      rel_p=$(echo "$p" | sed "s|^${TEMPLATES_DIR}/||")
      display_title="${t} (${rel_p})"
    fi
    TEMPLATES_TITLES+=("$display_title")
    TEMPLATES_BODIES+=("$b")
    TEMPLATES_PATHS+=("$p")
  done
}

# Resolve candidate generator command for custom variables
get_var_cmd() {
  local target_var="$1"
  # 1. Check _vars.txt
  if [ -f "$VARS_FILE" ]; then
    local cmd_line
    cmd_line=$(grep -E '^[$][[:space:]]*'"${target_var}"'[[:space:]]*:' "$VARS_FILE" 2>/dev/null | head -n 1)
    if [ -n "$cmd_line" ]; then
      echo "$cmd_line" | cut -d':' -f2- | sed 's/^[[:space:]]*//'
      return 0
    fi
  fi
  # 2. Check across all markdown templates (including subdirectories)
  if [ -d "$TEMPLATES_DIR" ]; then
    local cmd_line=""
    while IFS= read -r -d '' f; do
      cmd_line=$(grep -E '^[$][[:space:]]*'"${target_var}"'[[:space:]]*:' "$f" 2>/dev/null | head -n 1)
      if [ -n "$cmd_line" ]; then
        echo "$cmd_line" | cut -d':' -f2- | sed 's/^[[:space:]]*//'
        return 0
      fi
    done < <(find "$TEMPLATES_DIR" -type f -name "*.md" -print0 2>/dev/null)
  fi
  return 1
}

# Load prompt history options for fzf menu
load_history_options() {
  if [ -f "$HISTORY_FILE" ]; then
    while IFS= read -r line || [ -n "$line" ]; do
      # Skip empty lines or lines with only whitespace
      [[ "$line" =~ ^[[:space:]]*$ ]] && continue
      # Replace literal \n with space for a clean display title
      local clean_disp="${line//\\n/ }"
      if [ "${#clean_disp}" -gt 30 ]; then
        clean_disp="${clean_disp:0:30}..."
      fi
      printf '📜 %s\t%s\n' "$clean_disp" "$line"
    done < "$HISTORY_FILE"
  fi
}

# Save prompt to history file (limit to 50 items, remove duplicate)
save_to_history() {
  local text="$1"
  local escaped_text
  if command -v python3 &>/dev/null; then
    escaped_text=$(printf '%s' "$text" | python3 -c 'import sys
text = sys.stdin.read()
print(text.replace(r"\n", r"\\n").replace("\n", r"\n"), end="")
')
  else
    escaped_text=$(printf '%s' "$text" | awk '
      BEGIN { first = 1; out = "" }
      {
        line = $0
        gsub(/\\n/, "\\\\n", line)
        if (first) {
          out = line
          first = 0
        } else {
          out = out "\\n" line
        }
      }
      END { printf "%s", out }
    ')
  fi
  
  # Skip saving if the text is empty or contains only whitespace/newlines
  local check_content
  check_content=$(printf '%s' "$escaped_text" | sed -E 's/[[:space:]]|\\n//g')
  if [ -n "$check_content" ]; then
    mkdir -p "$(dirname "$HISTORY_FILE")"
    # Write new item and append existing items excluding duplicates atomically
    if [ -f "$HISTORY_FILE" ]; then
      (echo "$escaped_text"; grep -vxF -e "$escaped_text" -- "$HISTORY_FILE" 2>/dev/null || true) | head -n 50 > "${HISTORY_FILE}.tmp"
      mv "${HISTORY_FILE}.tmp" "$HISTORY_FILE"
    else
      echo "$escaped_text" > "$HISTORY_FILE"
    fi
  fi
}

# Get text from clipboard as fallback for selected text
get_clipboard_text() {
  if command -v pbpaste &>/dev/null; then
    pbpaste
  elif [ -n "$WAYLAND_DISPLAY" ] && command -v wl-paste &>/dev/null; then
    wl-paste 2>/dev/null
  elif command -v xclip &>/dev/null; then
    xclip -selection clipboard -o 2>/dev/null
  elif command -v xsel &>/dev/null; then
    xsel --clipboard --output 2>/dev/null
  elif command -v powershell.exe &>/dev/null; then
    # Fallback for WSL or Git Bash on Windows
    powershell.exe -NoProfile -Command Get-Clipboard 2>/dev/null | tr -d '\r'
  fi
}

# Detect a base branch (main/master/develop/trunk or origin/HEAD) different from current branch
resolve_git_base_branch() {
  local current_branch
  current_branch=$(safe_git branch --show-current 2>/dev/null)

  local origin_head
  origin_head=$(safe_git symbolic-ref --quiet --short refs/remotes/origin/HEAD 2>/dev/null)
  if [ -n "$origin_head" ]; then
    local origin_short="${origin_head#origin/}"
    if [ "$origin_short" != "$current_branch" ] && safe_git show-ref --verify --quiet "refs/heads/${origin_short}"; then
      echo "$origin_short"
      return 0
    fi
    if [ "$origin_short" != "$current_branch" ] || [ "$(safe_git rev-parse HEAD 2>/dev/null)" != "$(safe_git rev-parse "$origin_head" 2>/dev/null)" ]; then
      echo "$origin_head"
      return 0
    fi
  fi

  local candidate
  for candidate in main master develop trunk; do
    if [ "$candidate" != "$current_branch" ] && safe_git show-ref --verify --quiet "refs/heads/${candidate}"; then
      echo "$candidate"
      return 0
    fi
  done

  for candidate in origin/main origin/master origin/develop; do
    if safe_git show-ref --verify --quiet "refs/remotes/${candidate}"; then
      if [ "${candidate#origin/}" != "$current_branch" ] || [ "$(safe_git rev-parse HEAD 2>/dev/null)" != "$(safe_git rev-parse "$candidate" 2>/dev/null)" ]; then
        echo "$candidate"
        return 0
      fi
    fi
  done

  return 1
}

# Resolve git diff with unified 25-line preview truncation
resolve_git_diff_value() {
  local empty_msg="$1"
  local is_preview="$2"
  shift 2

  local diff_full
  diff_full=$(safe_git diff "$@" 2>/dev/null)
  if [ "$is_preview" == "true" ]; then
    if [ -z "$diff_full" ]; then
      printf '%s' "$empty_msg"
      return 0
    fi
    local line_count
    line_count=$(printf '%s\n' "$diff_full" | wc -l)
    if [ "$line_count" -gt 25 ]; then
      printf '%s\n...(truncated for preview)' "$(printf '%s\n' "$diff_full" | head -n 25)"
    else
      printf '%s' "$diff_full"
    fi
  else
    printf '%s' "$diff_full"
  fi
}

# Extract conflict hunks (with context) from all conflicted files
extract_git_conflicts() {
  local is_preview="$1"
  if ! safe_git rev-parse --is-inside-work-tree &>/dev/null; then
    printf '%s' "Not a git repository"
    return 0
  fi

  local git_root
  git_root=$(safe_git rev-parse --show-toplevel 2>/dev/null)
  local conflict_files=()
  while IFS= read -r -d '' rel_file; do
    [ -n "$rel_file" ] && conflict_files+=("$rel_file")
  done < <(safe_git diff --name-only --diff-filter=U -z 2>/dev/null)

  if [ "${#conflict_files[@]}" -eq 0 ]; then
    printf '%s' "No git merge conflicts detected"
    return 0
  fi

  local out=""
  for rel_file in "${conflict_files[@]}"; do
    local abs_file="${git_root}/${rel_file}"
    local section="=== ${rel_file} ==="
    if [ -f "$abs_file" ] && grep -q -E '^<<<<<<<' "$abs_file" 2>/dev/null; then
      local hunks
      hunks=$(awk '
        {
          lines[NR] = $0
        }
        /^<<<<<<</ {
          start = NR - 3
          if (start < 1) start = 1
          if (last_printed > 0 && start > last_printed + 1) print "--"
          if (start <= last_printed) start = last_printed + 1
          for (i = start; i <= NR; i++) {
            print lines[i]
            last_printed = i
          }
          in_conflict = 1
          post = 0
          next
        }
        in_conflict {
          print $0
          last_printed = NR
          if (/^>>>>>>>/) {
            in_conflict = 0
            post = 3
          }
          next
        }
        post > 0 {
          print $0
          last_printed = NR
          post--
        }
      ' "$abs_file")
      section="${section}"$'\n'"${hunks}"
    else
      section="${section}"$'\n'"(conflict without inline markers; check git status)"
    fi
    if [ -n "$out" ]; then
      out="${out}"$'\n\n'"${section}"
    else
      out="${section}"
    fi
  done

  if [ "$is_preview" == "true" ]; then
    local line_count
    line_count=$(printf '%s\n' "$out" | wc -l)
    if [ "$line_count" -gt 25 ]; then
      printf '%s\n...(truncated for preview)' "$(printf '%s\n' "$out" | head -n 25)"
      return 0
    fi
  fi
  printf '%s' "$out"
}

# List changed files (working tree, index, untracked, and current branch vs base)
list_git_changed_files() {
  local all_files=()
  local skip_next=0
  local rec
  while IFS= read -r -d '' rec; do
    if [ "$skip_next" -eq 1 ]; then
      skip_next=0
      continue
    fi
    [ -z "$rec" ] && continue
    local xy="${rec:0:2}"
    local p="${rec:3}"
    [ -n "$p" ] && all_files+=("$p")
    if [[ "$xy" == *R* ]] || [[ "$xy" == *C* ]]; then
      skip_next=1
    fi
  done < <(safe_git status --porcelain -uall -z 2>/dev/null)

  local base_branch
  base_branch=$(resolve_git_base_branch 2>/dev/null)
  if [ -n "$base_branch" ]; then
    local bf
    while IFS= read -r -d '' bf; do
      [ -n "$bf" ] && all_files+=("$bf")
    done < <(safe_git diff --name-only -z "${base_branch}...HEAD" 2>/dev/null)
  fi

  if [ "${#all_files[@]}" -gt 0 ]; then
    printf '%s\n' "${all_files[@]}" | awk 'NF && !seen[$0]++'
  fi
}

# Interactive fzf chooser for git commits (returns short commit SHA)
choose_git_commit() {
  local commits
  commits=$(safe_git log -n 200 --oneline --decorate 2>/dev/null)
  if [ -z "$commits" ]; then
    echo "No git commits found." >&2
    return 1
  fi
  local selected_line
  selected_line=$(printf '%s\n' "$commits" | fzf \
    --layout=reverse \
    --header="Select a git commit:" \
    --preview='bash -c '\''git --no-pager show --stat --color=always "$1" 2>/dev/null; echo "---"; git --no-pager show --color=always "$1" 2>/dev/null | head -n 80'\'' _ {1}' \
    --preview-window=right:50%:wrap)
  if [ -z "$selected_line" ]; then
    echo "Cancelled git commit selection." >&2
    return 1
  fi
  printf '%s' "$selected_line" | awk '{print $1}'
}

# Resolve all placeholders using non-recursive sentinel substitution
resolve_placeholders() {
  local prompt="$1"
  local is_preview="$2" # "true" or "false"

  local nonce="MUXPH_${$}_${RANDOM}"
  local tokens=()
  local values=()

  # 1. Interactive variables {{var:name}}
  local vars
  vars=$(echo "$prompt" | grep -oE "\{\{var:[a-zA-Z0-9_]+\}\}" | sort -u)
  for v in $vars; do
    local var_name
    var_name=$(echo "$v" | sed -E 's/\{\{var:([a-zA-Z0-9_]+)\}\}/\1/')
    local tok="__${nonce}_VAR_${var_name}__"
    prompt=$(safe_replace "$prompt" "$v" "$tok")

    local user_val=""
    if [ "$is_preview" == "true" ]; then
      user_val="[Enter value for $var_name]"
    else
      local cmd
      cmd=$(get_var_cmd "$var_name")
      if [ -n "$cmd" ]; then
        local candidates
        candidates=$(eval "$cmd" 2>/dev/null)
        if [ -n "$candidates" ]; then
          local fzf_status=0
          user_val=$(echo "$candidates" | fzf --layout=reverse --header="Select value for $var_name (Esc to enter manually):") || fzf_status=$?
          if [ "$fzf_status" -eq 130 ]; then
            user_val=""
          fi
        fi
      fi
      if [ -z "$user_val" ]; then
        echo -n "Enter value for [$var_name]: " >&2
        read -r user_val
      fi
    fi
    tokens+=("$tok")
    values+=("$user_val")
  done

  # 2. {{input}}
  if [[ "$prompt" == *"{{input}}"* ]]; then
    local tok="__${nonce}_INPUT__"
    prompt=$(safe_replace "$prompt" "{{input}}" "$tok")
    local user_input=""
    if [ "$is_preview" == "true" ]; then
      user_input="[Your custom input]"
    else
      echo "Enter your custom question/prompt (press Ctrl+D when finished):" >&2
      user_input=$(cat)
    fi
    tokens+=("$tok")
    values+=("$user_input")
  fi

  # 3. Git placeholders
  if [[ "$prompt" == *"{{git_diff:staged}}"* ]]; then
    local tok="__${nonce}_GITDIFFSTAGED__"
    prompt=$(safe_replace "$prompt" "{{git_diff:staged}}" "$tok")
    local diff_val
    diff_val=$(resolve_git_diff_value "No staged git changes" "$is_preview" --cached)
    tokens+=("$tok")
    values+=("$diff_val")
  fi

  if [[ "$prompt" == *"{{git_diff:branch}}"* ]]; then
    local tok="__${nonce}_GITDIFFBRANCH__"
    prompt=$(safe_replace "$prompt" "{{git_diff:branch}}" "$tok")
    local diff_val=""
    local base_branch
    base_branch=$(resolve_git_base_branch 2>/dev/null)
    if [ -n "$base_branch" ]; then
      diff_val=$(resolve_git_diff_value "No branch diff changes" "$is_preview" "${base_branch}...HEAD")
    else
      diff_val="No base branch found"
    fi
    tokens+=("$tok")
    values+=("$diff_val")
  fi

  if [[ "$prompt" == *"{{git_diff}}"* ]]; then
    local tok="__${nonce}_GITDIFF__"
    prompt=$(safe_replace "$prompt" "{{git_diff}}" "$tok")
    local diff_val
    diff_val=$(resolve_git_diff_value "No git changes" "$is_preview")
    tokens+=("$tok")
    values+=("$diff_val")
  fi

  if [[ "$prompt" == *"{{git_log:branch}}"* ]]; then
    local tok="__${nonce}_GITLOGBRANCH__"
    prompt=$(safe_replace "$prompt" "{{git_log:branch}}" "$tok")
    local log_val=""
    local base_branch
    base_branch=$(resolve_git_base_branch 2>/dev/null)
    if [ -n "$base_branch" ]; then
      log_val=$(safe_git log --oneline "${base_branch}..HEAD" 2>/dev/null)
      if [ -z "$log_val" ]; then
        log_val="No branch commits"
      fi
    else
      log_val="No base branch found"
    fi
    tokens+=("$tok")
    values+=("$log_val")
  fi

  if [[ "$prompt" == *"{{git_log}}"* ]]; then
    local tok="__${nonce}_GITLOG__"
    prompt=$(safe_replace "$prompt" "{{git_log}}" "$tok")
    local log_val
    log_val=$(safe_git log -n 10 --oneline 2>/dev/null)
    if [ -z "$log_val" ]; then
      log_val="No git commits found"
    fi
    tokens+=("$tok")
    values+=("$log_val")
  fi

  if [[ "$prompt" == *"{{git_status}}"* ]]; then
    local tok="__${nonce}_GITSTATUS__"
    prompt=$(safe_replace "$prompt" "{{git_status}}" "$tok")
    local status_val
    status_val=$(safe_git status -s 2>/dev/null || echo "Not a git repo")
    tokens+=("$tok")
    values+=("$status_val")
  fi

  if [[ "$prompt" == *"{{git_branch:choose}}"* ]]; then
    local tok="__${nonce}_GITBRANCHCHOOSE__"
    prompt=$(safe_replace "$prompt" "{{git_branch:choose}}" "$tok")
    local branch_val=""
    if [ "$is_preview" == "true" ]; then
      branch_val="[Selected git branch]"
    else
      local branches
      branches=$(safe_git for-each-ref --sort=-committerdate --format='%(refname:short)' refs/heads refs/remotes 2>/dev/null | grep -v -E '^origin/HEAD$|/HEAD$')
      if [ -z "$branches" ]; then
        echo "No git branches found." >&2
        exit 0
      fi
      branch_val=$(printf '%s\n' "$branches" | fzf \
        --layout=reverse \
        --header="Select a git branch:" \
        --preview='bash -c '\''git --no-pager log -n 20 --oneline --graph --decorate --color=always "$1" 2>/dev/null'\'' _ {}' \
        --preview-window=right:50%:wrap)
      if [ -z "$branch_val" ]; then
        echo "Cancelled git branch selection." >&2
        exit 0
      fi
    fi
    tokens+=("$tok")
    values+=("$branch_val")
  fi

  if [[ "$prompt" == *"{{git_branch}}"* ]]; then
    local tok="__${nonce}_GITBRANCH__"
    prompt=$(safe_replace "$prompt" "{{git_branch}}" "$tok")
    local branch_val
    branch_val=$(safe_git branch --show-current 2>/dev/null || echo "no-branch")
    tokens+=("$tok")
    values+=("$branch_val")
  fi

  if [[ "$prompt" == *"{{git_commit:diff}}"* ]]; then
    local tok="__${nonce}_GITCOMMITDIFF__"
    prompt=$(safe_replace "$prompt" "{{git_commit:diff}}" "$tok")
    local commit_diff_val=""
    if [ "$is_preview" == "true" ]; then
      commit_diff_val="[Diff of selected git commit]"
    else
      local selected_sha
      selected_sha=$(choose_git_commit) || exit 0
      commit_diff_val=$(safe_git show "$selected_sha" 2>/dev/null)
    fi
    tokens+=("$tok")
    values+=("$commit_diff_val")
  fi

  if [[ "$prompt" == *"{{git_commit}}"* ]]; then
    local tok="__${nonce}_GITCOMMIT__"
    prompt=$(safe_replace "$prompt" "{{git_commit}}" "$tok")
    local commit_val=""
    if [ "$is_preview" == "true" ]; then
      commit_val="[Selected git commit hash]"
    else
      commit_val=$(choose_git_commit) || exit 0
    fi
    tokens+=("$tok")
    values+=("$commit_val")
  fi

  if [[ "$prompt" == *"{{git_conflicts}}"* ]]; then
    local tok="__${nonce}_GITCONFLICTS__"
    prompt=$(safe_replace "$prompt" "{{git_conflicts}}" "$tok")
    local conflicts_val
    conflicts_val=$(extract_git_conflicts "$is_preview")
    tokens+=("$tok")
    values+=("$conflicts_val")
  fi

  if [[ "$prompt" == *"{{git_changed_file}}"* ]]; then
    local tok="__${nonce}_GITCHANGEDFILE__"
    prompt=$(safe_replace "$prompt" "{{git_changed_file}}" "$tok")
    local changed_file_val=""
    if [ "$is_preview" == "true" ]; then
      changed_file_val="[Path of selected changed file]"
    else
      if ! safe_git rev-parse --is-inside-work-tree &>/dev/null; then
        echo "Not inside a git repository." >&2
        exit 0
      fi
      local git_root changed_files
      git_root=$(safe_git rev-parse --show-toplevel 2>/dev/null)
      changed_files=$(list_git_changed_files)
      if [ -z "$changed_files" ]; then
        echo "No changed files found." >&2
        exit 0
      fi
      changed_file_val=$(printf '%s\n' "$changed_files" | PROMPTER_GIT_ROOT="$git_root" fzf \
        --layout=reverse \
        --header="Select a changed file:" \
        --preview='bash -c '\''root="$PROMPTER_GIT_ROOT"; f="$1"; d=$(git --no-pager -C "$root" diff -- "$f" 2>/dev/null); dc=$(git --no-pager -C "$root" diff --cached -- "$f" 2>/dev/null); if [ -n "$d" ] || [ -n "$dc" ]; then [ -n "$dc" ] && echo "=== Staged ===" && printf "%s\n" "$dc"; [ -n "$d" ] && echo "=== Unstaged ===" && printf "%s\n" "$d"; elif [ -f "$root/$f" ]; then head -n 60 "$root/$f"; else echo "(deleted or missing)"; fi'\'' _ {}' \
        --preview-window=right:50%:wrap)
      if [ -z "$changed_file_val" ]; then
        echo "Cancelled changed file selection." >&2
        exit 0
      fi
    fi
    tokens+=("$tok")
    values+=("$changed_file_val")
  fi

  if [[ "$prompt" == *"{{git_worktree}}"* ]]; then
    local tok="__${nonce}_GITWORKTREE__"
    prompt=$(safe_replace "$prompt" "{{git_worktree}}" "$tok")
    local wt_val=""
    if [ "$is_preview" == "true" ]; then
      wt_val="[Path of selected git worktree]"
    else
      local porcelain_out
      porcelain_out=$(safe_git worktree list --porcelain 2>/dev/null)
      if [ -z "$porcelain_out" ]; then
        echo "Not inside a git repository or no worktrees found." >&2
        exit 0
      fi

      local current_wt=""
      current_wt=$(safe_git rev-parse --show-toplevel 2>/dev/null)
      if [ -n "$current_wt" ] && [ -d "$current_wt" ]; then
        current_wt=$(cd "$current_wt" 2>/dev/null && pwd -P)
      fi

      local wt_options
      wt_options=$(printf '%s\n' "$porcelain_out" | CUR_WT="$current_wt" awk '
        BEGIN {
          cur = ENVIRON["CUR_WT"]
        }
        function flush_entry() {
          if (path == "") return
          if (is_bare) {
            label = "bare"
          } else if (branch != "") {
            sub(/^refs\/heads\//, "", branch)
            label = branch
          } else if (is_detached) {
            label = "detached" (head != "" ? " @ " substr(head, 1, 7) : "")
          } else {
            label = "unknown"
          }
          marker = (cur != "" && path == cur) ? "* " : "  "
          printf "%s[%s] %s\t%s\n", marker, label, path, path
          path = ""; head = ""; branch = ""; is_bare = 0; is_detached = 0
        }
        /^worktree / { flush_entry(); path = substr($0, 10); next }
        /^HEAD /     { head = substr($0, 6); next }
        /^branch /   { branch = substr($0, 8); next }
        /^bare$/     { is_bare = 1; next }
        /^detached$/ { is_detached = 1; next }
        /^[[:space:]]*$/ { flush_entry(); next }
        END { flush_entry() }
      ')

      if [ -z "$wt_options" ]; then
        echo "No git worktrees found." >&2
        exit 0
      fi

      local selected_wt_line
      selected_wt_line=$(printf '%s\n' "$wt_options" | fzf \
        --layout=reverse \
        --delimiter=$'\t' \
        --with-nth=1 \
        --header="Select a git worktree:" \
        --preview='bash -c '\''if [ -d "$1" ]; then git --no-pager -C "$1" status -sb 2>/dev/null || echo "(bare repository)"; echo "---"; git --no-pager -C "$1" log -n 5 --oneline --decorate 2>/dev/null; else echo "(directory missing)"; fi'\'' _ {2}' \
        --preview-window=right:50%:wrap)

      if [ -n "$selected_wt_line" ]; then
        wt_val=$(printf '%s' "$selected_wt_line" | awk -F'\t' '{print $NF}')
      else
        echo "Cancelled git worktree selection." >&2
        exit 0
      fi
    fi
    tokens+=("$tok")
    values+=("$wt_val")
  fi

  # 4. Scrollback context
  if [[ "$prompt" == *"{{pane_logs:errors}}"* ]]; then
    local tok="__${nonce}_PANELOGSERRORS__"
    prompt=$(safe_replace "$prompt" "{{pane_logs:errors}}" "$tok")
    local filtered_logs=""
    if [ "$is_preview" == "true" ]; then
      filtered_logs="[Target pane logs (Errors only)]"
    else
      local logs
      logs=$(mux_read_pane_logs "$TARGET_PANE_ID" 100)
      logs=$(echo "$logs" | sed -E 's/\x1B\[[0-9;]*[a-zA-Z]//g')
      filtered_logs=$(echo "$logs" | grep -i -B 3 -A 3 -E "error|fail|exception|fatal|panic")
      if [ -z "$filtered_logs" ]; then
        filtered_logs="No errors found in the last 100 lines of logs."
      fi
    fi
    tokens+=("$tok")
    values+=("$filtered_logs")
  fi

  if [[ "$prompt" == *"{{pane_logs}}"* ]]; then
    local tok="__${nonce}_PANELOGS__"
    prompt=$(safe_replace "$prompt" "{{pane_logs}}" "$tok")
    local logs_val=""
    if [ "$is_preview" == "true" ]; then
      logs_val="[Target pane logs (last 100 lines)]"
    else
      local logs
      logs=$(mux_read_pane_logs "$TARGET_PANE_ID" 100)
      logs=$(echo "$logs" | sed -E 's/\x1B\[[0-9;]*[a-zA-Z]//g')
      logs_val="$logs"
    fi
    tokens+=("$tok")
    values+=("$logs_val")
  fi

  if [[ "$prompt" == *"{{last_command}}"* ]]; then
    local tok="__${nonce}_LASTCOMMAND__"
    prompt=$(safe_replace "$prompt" "{{last_command}}" "$tok")
    local cmd_val=""
    if [ "$is_preview" == "true" ]; then
      cmd_val="[Last executed command]"
    else
      local logs
      logs=$(mux_read_pane_logs "$TARGET_PANE_ID" 100)
      logs=$(echo "$logs" | sed -E 's/\x1B\][^\x07]*\x07//g; s/\x1B\[[0-9;]*[a-zA-Z]//g; s/\x1B[()][A-Z0-9]//g')
      local last_cmd=""
      while IFS= read -r line || [ -n "$line" ]; do
        [[ "$line" =~ ^[[:space:]]*$ ]] && continue
        
        local cmd_candidate=""
        # Case A: oh-my-zsh style: ➜  dir git:(main) ✗ cmd
        if echo "$line" | grep -q -E "^➜[[:space:]]+.*git:\([^)]+\)[[:space:]]*[^[:space:]]*[[:space:]]+"; then
          cmd_candidate=$(echo "$line" | sed -E "s/^➜[[:space:]]+.*git:\([^)]+\)[[:space:]]*[^[:space:]]*[[:space:]]+//")
        # Case B: oh-my-zsh simple: ➜  dir cmd
        elif echo "$line" | grep -q -E "^➜[[:space:]]+"; then
          cmd_candidate=$(echo "$line" | sed -E "s/^➜[[:space:]]+[^[:space:]]+[[:space:]]+//")
        # Case C: Unicode prompt terminators (❯, ▶, )
        elif echo "$line" | grep -q -E "(❯|▶|)[[:space:]]+"; then
          cmd_candidate=$(echo "$line" | sed -E 's/^.*(❯|▶|)[[:space:]]+//')
        # Case D: Standard prompt terminator ($ or % or #) with trailing space
        elif echo "$line" | grep -q -E "(\\\$|%|#)[[:space:]]+"; then
          cmd_candidate=$(echo "$line" | sed -E 's/^[^\$#%]*[\$#%][[:space:]]+//')
        fi
        
        # Strip Powerline right-prompt ()
        cmd_candidate=$(echo "$cmd_candidate" | sed -E 's/[[:space:]]*.*$//')
        # Strip right-prompt (RPROMPT / timestamps separated by wide margin of 5+ spaces)
        cmd_candidate=$(echo "$cmd_candidate" | sed -E 's/[[:space:]]{5,}.*$//')
        cmd_candidate=$(echo "$cmd_candidate" | sed -E 's/^[[:space:]]+|[[:space:]]+$//g')
        
        if [ -n "$cmd_candidate" ]; then
          last_cmd="$cmd_candidate"
          break
        fi
      done <<< "$(echo "$logs" | tail -n 100 | awk '{a[i++]=$0} END {for (j=i-1; j>=0; j--) print a[j]}')"

      if [ -n "$last_cmd" ]; then
        cmd_val="$last_cmd"
      else
        echo "Could not detect last command automatically." >&2
        echo "Enter the command manually (press Enter):" >&2
        read -r manual_cmd
        cmd_val="$manual_cmd"
      fi
    fi
    tokens+=("$tok")
    values+=("$cmd_val")
  fi

  # 5. Cross-pane referencing & Broadcast target
  if [[ "$prompt" == *"{{panes:choose}}"* ]]; then
    local tok="__${nonce}_PANESCHOOSE__"
    prompt=$(safe_replace "$prompt" "{{panes:choose}}" "$tok")
    local panes_val=""
    if [ "$is_preview" == "true" ]; then
      panes_val="[Selected Broadcast Panes]"
    else
      local pane_options
      pane_options=$(mux_list_panes)
      if [ -n "$pane_options" ]; then
        # Multi-selection fzf
        local selected_panes_lines
        selected_panes_lines=$(echo "$pane_options" | fzf --layout=reverse -m --header="Select target panes for broadcast (Tab to select multiple, Enter to confirm):")
        if [ -n "$selected_panes_lines" ]; then
          TARGET_PANES=()
          local pane_labels=""
          while read -r line; do
            [ -z "$line" ] && continue
            local pid=""
            if [[ "$line" =~ ^Pane[[:space:]]+([a-zA-Z0-9_-]+) ]]; then
              pid="${BASH_REMATCH[1]}"
            else
              pid=$(echo "$line" | grep -oE "(%[0-9]+|terminal_[0-9]+|surface:[a-zA-Z0-9_-]+|[a-zA-Z0-9_-]+:p[a-zA-Z0-9_-]+)" | head -n 1)
            fi
            if [ -z "$pid" ]; then
              pid=$(echo "$line" | awk -F'|' '{print $2}' | sed 's/^[[:space:]]*//;s/[[:space:]]*$//' | awk '{print $1}')
            fi
            if [ -z "$pid" ]; then
              pid=$(echo "$line" | awk -F'|' '{print $1}' | sed 's/^[[:space:]]*//;s/[[:space:]]*$//;s/^Surface[[:space:]]*//')
            fi
            [ -n "$pid" ] && TARGET_PANES+=("$pid") && pane_labels="${pane_labels}${pid} "
          done <<< "$selected_panes_lines"
          panes_val="${pane_labels}"
        else
          echo "Cancelled pane selection." >&2
          exit 0
        fi
      else
        echo "No other panes found." >&2
        panes_val="No other panes"
      fi
    fi
    tokens+=("$tok")
    values+=("$panes_val")
  fi

  if [[ "$prompt" == *"{{pane:choose}}"* ]]; then
    local tok="__${nonce}_PANECHOOSE__"
    prompt=$(safe_replace "$prompt" "{{pane:choose}}" "$tok")
    local pane_val=""
    if [ "$is_preview" == "true" ]; then
      pane_val="[Content of selected pane]"
    else
      local pane_options
      pane_options=$(mux_list_panes)
      if [ -n "$pane_options" ]; then
        local selected_pane_line
        selected_pane_line=$(echo "$pane_options" | fzf --layout=reverse --header="Select a pane to import logs from:")
        if [ -n "$selected_pane_line" ]; then
          local selected_pane_id=""
          if [[ "$selected_pane_line" =~ ^Pane[[:space:]]+([a-zA-Z0-9_-]+) ]]; then
            selected_pane_id="${BASH_REMATCH[1]}"
          else
            selected_pane_id=$(echo "$selected_pane_line" | grep -oE "(%[0-9]+|terminal_[0-9]+|surface:[a-zA-Z0-9_-]+|[a-zA-Z0-9_-]+:p[a-zA-Z0-9_-]+)" | head -n 1)
          fi
          if [ -z "$selected_pane_id" ]; then
            selected_pane_id=$(echo "$selected_pane_line" | awk -F'|' '{print $2}' | sed 's/^[[:space:]]*//;s/[[:space:]]*$//' | awk '{print $1}')
          fi
          if [ -z "$selected_pane_id" ]; then
            selected_pane_id=$(echo "$selected_pane_line" | awk -F'|' '{print $1}' | sed 's/^[[:space:]]*//;s/[[:space:]]*$//;s/^Surface[[:space:]]*//')
          fi
          local imported_logs
          imported_logs=$(mux_read_pane_logs "$selected_pane_id" 100)
          imported_logs=$(echo "$imported_logs" | sed -E 's/\x1B\[[0-9;]*[a-zA-Z]//g')
          pane_val="$imported_logs"
          TARGET_PANES=("$selected_pane_id")
        else
          echo "Cancelled pane selection." >&2
          exit 0
        fi
      else
        echo "No other panes found." >&2
        pane_val="No other panes"
      fi
    fi
    tokens+=("$tok")
    values+=("$pane_val")
  fi

  # 6. Smart File truncation {{file:lines=START-END}}
  local file_lines_matches
  file_lines_matches=$(echo "$prompt" | grep -oE "\{\{file:lines=[0-9]+-[0-9]+\}\}" | sort -u)
  for flm in $file_lines_matches; do
    if [[ "$flm" =~ \{\{file:lines=([0-9]+)-([0-9]+)\}\} ]]; then
      local start_line="${BASH_REMATCH[1]}"
      local end_line="${BASH_REMATCH[2]}"
      local tok="__${nonce}_FILELINES_${start_line}_${end_line}__"
      prompt=$(safe_replace "$prompt" "$flm" "$tok")
      local fl_val=""
      if [ "$is_preview" == "true" ]; then
        fl_val="[Content of selected file (lines ${start_line}-${end_line})]"
      else
        local file_path=""
        if safe_git rev-parse --is-inside-work-tree &>/dev/null; then
          local git_root
          git_root=$(safe_git rev-parse --show-toplevel)
          file_path=$(cd "$git_root" && (safe_git status -s | cut -c4-; safe_git ls-files) | sort -u | fzf --layout=reverse --header="Select a file to insert (lines ${start_line}-${end_line}):")
          if [ -n "$file_path" ]; then
            file_path="${git_root}/${file_path}"
          fi
        else
          file_path=$(fzf --layout=reverse --header="Select a file to insert (lines ${start_line}-${end_line}):" <<< "$(find . -maxdepth 3 -type f -not -path '*/.*' 2>/dev/null | sed 's|^\./||')")
        fi
        
        if [ -n "$file_path" ] && [ -f "$file_path" ]; then
          fl_val=$(sed -n "${start_line},${end_line}p" "$file_path")
        else
          echo "Cancelled file selection." >&2
          exit 0
        fi
      fi
      tokens+=("$tok")
      values+=("$fl_val")
    fi
  done

  # 7. File Content placeholder {{file}}
  if [[ "$prompt" == *"{{file}}"* ]]; then
    local tok="__${nonce}_FILE__"
    prompt=$(safe_replace "$prompt" "{{file}}" "$tok")
    local file_val=""
    if [ "$is_preview" == "true" ]; then
      file_val="[Content of selected file]"
    else
      local file_path=""
      if safe_git rev-parse --is-inside-work-tree &>/dev/null; then
        local git_root
        git_root=$(safe_git rev-parse --show-toplevel)
        file_path=$(cd "$git_root" && (safe_git status -s | cut -c4-; safe_git ls-files) | sort -u | fzf --layout=reverse --header="Select a file to insert (Git Root: $(basename "$git_root")):")
        if [ -n "$file_path" ]; then
          file_path="${git_root}/${file_path}"
        fi
      else
        file_path=$(fzf --layout=reverse --header="Select a file to insert:" <<< "$(find . -maxdepth 3 -type f -not -path '*/.*' 2>/dev/null | sed 's|^\./||')")
      fi
      
      if [ -n "$file_path" ] && [ -f "$file_path" ]; then
        file_val=$(cat "$file_path")
      else
        echo "Cancelled file selection." >&2
        exit 0
      fi
    fi
    tokens+=("$tok")
    values+=("$file_val")
  fi

  # 8. File Path placeholder {{file_path}}, {{filepath}}, {{file:path}}
  if [[ "$prompt" == *"{{file_path}}"* ]] || [[ "$prompt" == *"{{filepath}}"* ]] || [[ "$prompt" == *"{{file:path}}"* ]]; then
    local tok="__${nonce}_FILEPATH__"
    prompt=$(safe_replace "$prompt" "{{file_path}}" "$tok")
    prompt=$(safe_replace "$prompt" "{{filepath}}" "$tok")
    prompt=$(safe_replace "$prompt" "{{file:path}}" "$tok")
    local path_val=""
    if [ "$is_preview" == "true" ]; then
      path_val="[Path of selected file]"
    else
      local file_path=""
      if safe_git rev-parse --is-inside-work-tree &>/dev/null; then
        local git_root
        git_root=$(safe_git rev-parse --show-toplevel)
        file_path=$(cd "$git_root" && (safe_git status -s | cut -c4-; safe_git ls-files) | sort -u | fzf --layout=reverse --header="Select a file to insert path:")
      else
        file_path=$(fzf --layout=reverse --header="Select a file to insert path:" <<< "$(find . -maxdepth 3 -type f -not -path '*/.*' 2>/dev/null | sed 's|^\./||')")
      fi
      
      if [ -n "$file_path" ]; then
        path_val="$file_path"
      else
        echo "Cancelled file selection." >&2
        exit 0
      fi
    fi
    tokens+=("$tok")
    values+=("$path_val")
  fi

  # 9. {{error}}
  if [[ "$prompt" == *"{{error}}"* ]]; then
    local tok="__${nonce}_ERROR__"
    prompt=$(safe_replace "$prompt" "{{error}}" "$tok")
    local error_val=""
    if [ "$is_preview" == "true" ]; then
      error_val="[Recent target pane error logs]"
    else
      local pane_logs
      pane_logs=$(mux_read_pane_logs "$TARGET_PANE_ID" 50)
      if [ -n "$pane_logs" ]; then
        local pane_logs_clean
        pane_logs_clean=$(echo "$pane_logs" | sed -E 's/\x1B\][^\x07]*\x07//g; s/\x1B\[[0-9;]*[a-zA-Z]//g; s/\x1B[()][A-Z0-9]//g')
        local err_info
        err_info=$(echo "$pane_logs_clean" | grep -i -E "error|fail|exception|fatal|panic|err:" | tail -n 15)
        if [ -z "$err_info" ]; then
          err_info="No explicit errors (error/fail/panic/exception) detected in the last 50 lines."
        fi
        error_val="$err_info"
      else
        echo "Could not read terminal output automatically." >&2
        echo "Enter the error message manually (press Ctrl+D when finished):" >&2
        local manual_error
        manual_error=$(cat)
        error_val="$manual_error"
      fi
    fi
    tokens+=("$tok")
    values+=("$error_val")
  fi

  # 10. {{selected}}
  if [[ "$prompt" == *"{{selected}}"* ]]; then
    local tok="__${nonce}_SELECTED__"
    prompt=$(safe_replace "$prompt" "{{selected}}" "$tok")
    tokens+=("$tok")
    values+=("$SELECTED_TEXT")
  fi

  # 11. Final token replacement (single-pass non-recursive resolution)
  for i in "${!tokens[@]}"; do
    prompt=$(safe_replace "$prompt" "${tokens[$i]}" "${values[$i]}")
  done

  RESOLVED_PROMPT="$prompt"
}

# --- Handle Option List Modes (for fzf reload) ---
if [ "$1" == "--list-templates" ]; then
  load_templates
  for title in "${TEMPLATES_TITLES[@]}"; do
    [ -n "$title" ] && echo "$title"
  done
  echo "🔧 Edit Templates"
  exit 0
fi

if [ "$1" == "--list-history" ]; then
  load_history_options
  exit 0
fi

if [ "$1" == "--list-all" ]; then
  load_history_options
  load_templates
  for title in "${TEMPLATES_TITLES[@]}"; do
    [ -n "$title" ] && echo "$title"
  done
  echo "🔧 Edit Templates"
  exit 0
fi

# --- Handle Preview Mode ---
if [ "$1" == "--preview-only" ]; then
  SELECTED_TITLE=$(printf '%s' "$2" | tr -d '\r')
  CONTEXT_JSON="${3:-$HERDR_PLUGIN_CONTEXT_JSON}"
  
  # Parse context for preview
  TARGET_PANE_ID=$(mux_get_target_pane_id "$CONTEXT_JSON")
  WORKSPACE_CWD=$(mux_get_workspace_cwd "$CONTEXT_JSON")
  SELECTED_TEXT=$(mux_get_selected_text "$CONTEXT_JSON")
  
  if [ -n "$WORKSPACE_CWD" ] && [ -d "$WORKSPACE_CWD" ]; then
    cd "$WORKSPACE_CWD" || exit 1
  fi
  
  # Handle history item preview
  if [[ "$SELECTED_TITLE" == *"	"* ]]; then
    escaped_history=$(printf '%s' "$SELECTED_TITLE" | cut -d$'\t' -f2-)
    decode_literal_newlines "$escaped_history"
    exit 0
  elif [[ "$SELECTED_TITLE" == "📜 "* ]]; then
    escaped_history=$(printf '%s' "$SELECTED_TITLE" | cut -d'|' -f2- | sed 's/^[[:space:]]*//')
    decode_literal_newlines "$escaped_history"
    exit 0
  fi
  
  load_templates
  
  # Find matching template body
  TEMPLATE_BODY=""
  for i in "${!TEMPLATES_TITLES[@]}"; do
    if [ "${TEMPLATES_TITLES[$i]}" == "$SELECTED_TITLE" ]; then
      TEMPLATE_BODY="${TEMPLATES_BODIES[$i]}"
      break
    fi
  done
  
  if [ -z "$TEMPLATE_BODY" ]; then
    if [ "$SELECTED_TITLE" == "🔧 Edit Templates" ]; then
      echo "Open templates directory: $TEMPLATES_DIR"
    else
      echo "No template found."
    fi
    exit 0
  fi
  
  # Output the preview
  resolve_placeholders "$TEMPLATE_BODY" "true"
  printf '%s\n' "$RESOLVED_PROMPT"
  exit 0
fi

# --- Standard Plugin Flow ---
# Parse context
TARGET_PANE_ID=$(mux_get_target_pane_id "$HERDR_PLUGIN_CONTEXT_JSON")
WORKSPACE_CWD=$(mux_get_workspace_cwd "$HERDR_PLUGIN_CONTEXT_JSON")
SELECTED_TEXT=$(mux_get_selected_text "$HERDR_PLUGIN_CONTEXT_JSON")

if [ -z "$TARGET_PANE_ID" ]; then
  TARGET_PANE_ID="current"
fi

if [ -n "$WORKSPACE_CWD" ] && [ -d "$WORKSPACE_CWD" ]; then
  cd "$WORKSPACE_CWD" || exit 1
fi

# Target Panes initialization
TARGET_PANES=("$TARGET_PANE_ID")

# Export variables for child fzf reload processes
export HERDR_BIN
export TMUX_BIN
export ZELLIJ_BIN
export MUX_BACKEND
export CURRENT_BACKEND
export CONFIG_DIR
export TEMPLATES_DIR
export VARS_FILE
export HISTORY_FILE
export HERDR_PLUGIN_CONTEXT_JSON
export SCRIPT_PATH

# Main selection and execution loop
while true; do
  load_templates

  # Build initial options in memory so SIGPIPE-ignored parents do not emit Broken pipe
  # if fzf exits before an upstream sed/subprocess pipe finishes flushing.
  initial_options=""
  for title in "${TEMPLATES_TITLES[@]}"; do
    [ -n "$title" ] && initial_options+="${title}"$'\n'
  done
  initial_options+="🔧 Edit Templates"

  # Run fzf with preview panel enabled and dynamic reload binding
  # Default view: Templates
  SELECTED_OPTION=$(fzf \
    --header="[Ctrl-T] Templates  |  [Ctrl-R] History  |  [Ctrl-A] All Options" \
    --prompt="Templates> " \
    --layout=reverse \
    --delimiter=$'\t' \
    --with-nth=1 \
    --preview="bash \"$SCRIPT_PATH\" --preview-only {}" \
    --preview-window=right:50%:wrap \
    --bind "ctrl-r:reload(bash \"$SCRIPT_PATH\" --list-history)+change-prompt(History> )" \
    --bind "ctrl-t:reload(bash \"$SCRIPT_PATH\" --list-templates)+change-prompt(Templates> )" \
    --bind "ctrl-a:reload(bash \"$SCRIPT_PATH\" --list-all)+change-prompt(All> )" <<< "$initial_options")

  if [ -z "$SELECTED_OPTION" ]; then
    exit 0
  fi

  FINAL_PROMPT=""

  # Handle history selection
  if [[ "$SELECTED_OPTION" == *"	"* ]]; then
    escaped_prompt=$(printf '%s' "$SELECTED_OPTION" | cut -d$'\t' -f2-)
    FINAL_PROMPT=$(decode_literal_newlines "$escaped_prompt")
    
    # Re-save to push to top of history
    save_to_history "$FINAL_PROMPT"
    break
  elif [[ "$SELECTED_OPTION" == "📜 "* ]]; then
    # Fallback for legacy history line format
    escaped_prompt=$(printf '%s' "$SELECTED_OPTION" | cut -d'|' -f2- | sed 's/^[[:space:]]*//')
    FINAL_PROMPT=$(decode_literal_newlines "$escaped_prompt")
    
    # Re-save to push to top of history
    save_to_history "$FINAL_PROMPT"
    break
  elif [ "$SELECTED_OPTION" == "🔧 Edit Templates" ]; then
    MY_EDITOR="${VISUAL:-${EDITOR:-nano}}"
    editor_bin=$(echo "$MY_EDITOR" | awk '{print $1}')
    if ! command -v "$editor_bin" &>/dev/null; then
      if command -v nano &>/dev/null; then
        MY_EDITOR="nano"
      else
        MY_EDITOR="vi"
      fi
    fi
    
    # Prompt user to choose template to edit or create new template
    edit_choices=("➕ [Create New Template]")
    for i in "${!TEMPLATES_TITLES[@]}"; do
      rel_name=$(basename "${TEMPLATES_PATHS[$i]}")
      edit_choices+=("${TEMPLATES_TITLES[$i]} (${rel_name})")
    done
    
    edit_out=$(printf '%s\n' "${edit_choices[@]}" | fzf \
      --layout=reverse \
      --header="[Enter] Edit  |  [Ctrl-D] Delete  |  [Esc] Back" \
      --expect=ctrl-d)
    
    if [ -z "$edit_out" ]; then
      continue
    fi
    
    key_pressed=$(echo "$edit_out" | head -n 1)
    selected_edit=$(echo "$edit_out" | sed '1d')
    # Fallback if mock returns single line without header
    if [ -z "$selected_edit" ] && [ -n "$key_pressed" ] && [ "$key_pressed" != "ctrl-d" ]; then
      selected_edit="$key_pressed"
      key_pressed=""
    fi
    
    if [ -z "$selected_edit" ]; then
      continue
    fi
    
    # Handle deletion via Ctrl-D
    if [ "$key_pressed" == "ctrl-d" ]; then
      if [ "$selected_edit" == "➕ [Create New Template]" ]; then
        continue
      fi
      target_del_file=""
      for i in "${!TEMPLATES_TITLES[@]}"; do
        rel_name=$(basename "${TEMPLATES_PATHS[$i]}")
        if [ "$selected_edit" == "${TEMPLATES_TITLES[$i]} (${rel_name})" ]; then
          target_del_file="${TEMPLATES_PATHS[$i]}"
          break
        fi
      done
      if [ -n "$target_del_file" ] && [ -f "$target_del_file" ]; then
        echo -n "Delete template '$(basename "$target_del_file")'? [y/N]: " >&2
        read -r confirm_del
        if [[ "$confirm_del" =~ ^[yY] ]]; then
          rm -f "$target_del_file"
          echo "Deleted template $(basename "$target_del_file")" >&2
        fi
      fi
      continue
    fi
    
    target_edit_file=""
    if [ "$selected_edit" == "➕ [Create New Template]" ]; then
      echo -n "Enter new template title (or Enter to cancel): " >&2
      read -r new_title
      if [ -z "$new_title" ]; then
        continue
      fi
      new_slug=$(slugify "$new_title")
      target_edit_file="${TEMPLATES_DIR}/${new_slug}.md"
      count=1
      while [ -f "$target_edit_file" ]; do
        count=$((count + 1))
        target_edit_file="${TEMPLATES_DIR}/${new_slug}-${count}.md"
      done
      {
        echo "# ${new_title}"
        echo ""
        echo "Enter your prompt here..."
      } > "$target_edit_file"
    else
      for i in "${!TEMPLATES_TITLES[@]}"; do
        rel_name=$(basename "${TEMPLATES_PATHS[$i]}")
        if [ "$selected_edit" == "${TEMPLATES_TITLES[$i]} (${rel_name})" ]; then
          target_edit_file="${TEMPLATES_PATHS[$i]}"
          break
        fi
      done
    fi
    
    if [ -n "$target_edit_file" ]; then
      clear
      echo "Opening template: $target_edit_file"
      eval "$MY_EDITOR \"\$target_edit_file\""
    fi
    # Loop back to main menu after editor exits
    continue
  else
    # Find the matching template body
    TEMPLATE_BODY=""
    for i in "${!TEMPLATES_TITLES[@]}"; do
      if [ "${TEMPLATES_TITLES[$i]}" == "$SELECTED_OPTION" ]; then
        TEMPLATE_BODY="${TEMPLATES_BODIES[$i]}"
        break
      fi
    done

    # Resolve placeholders in execution mode
    resolve_placeholders "$TEMPLATE_BODY" "false"
    FINAL_PROMPT="$RESOLVED_PROMPT"
    
    # Save the finalized prompt (if not empty)
    if [ -n "$FINAL_PROMPT" ]; then
      save_to_history "$FINAL_PROMPT"
    fi
    break
  fi
done

# Inject into the target pane(s) (always safely insert into buffer)
for target_pid in "${TARGET_PANES[@]}"; do
  mux_send_text "$target_pid" "$FINAL_PROMPT"
done

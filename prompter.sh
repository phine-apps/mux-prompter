#!/usr/bin/env bash
# Mux Prompter - Fuzzy-pick and inject context-aware prompts into Herdr & tmux panes
# SPDX-License-Identifier: MIT

## Absolute path of this script to allow self-invocation after directory changes
SCRIPT_PATH="$(cd "$(dirname "$0")" && pwd)/$(basename "$0")"

# Multiplexer CLI paths & backend configuration
HERDR_BIN="${HERDR_BIN_PATH:-herdr}"
TMUX_BIN="${TMUX_BIN_PATH:-tmux}"
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
    # Fallback to awk (robust standard tool, memory-accumulated to bypass BSD/GNU RS differences)
    printf '%s' "$content" | awk -v t="$target" -v r="$replacement" '
      {
        content = (NR == 1) ? $0 : content "\n" $0
      }
      END {
        gsub(/\\/, "\\\\", r)
        gsub(/&/, "\\\\&", r)
        split(content, parts, t)
        out = parts[1]
        for (i = 2; i <= length(parts); i++) {
          out = out r parts[i]
        }
        printf "%s", out
      }
    '
  fi
}

# Detect active multiplexer backend (herdr or tmux)
detect_backend() {
  if [ "$MUX_BACKEND_CONF" = "tmux" ]; then
    echo "tmux"
    return 0
  elif [ "$MUX_BACKEND_CONF" = "herdr" ]; then
    echo "herdr"
    return 0
  fi

  # Auto-detection based on environment variables and active CLI responsiveness
  if [ -n "$TMUX" ]; then
    echo "tmux"
  elif [ -n "$HERDR_PLUGIN_CONTEXT_JSON" ]; then
    echo "herdr"
  elif command -v "$TMUX_BIN" &>/dev/null && "$TMUX_BIN" info &>/dev/null; then
    echo "tmux"
  elif command -v "$HERDR_BIN" &>/dev/null; then
    echo "herdr"
  elif command -v "$TMUX_BIN" &>/dev/null; then
    echo "tmux"
  else
    echo "herdr"
  fi
}

CURRENT_BACKEND=$(detect_backend)

# Abstracted Multiplexer Operations

mux_get_target_pane_id() {
  local context_json="${1:-$HERDR_PLUGIN_CONTEXT_JSON}"
  if [ "$CURRENT_BACKEND" = "tmux" ]; then
    if [ -n "$PROMPTER_TARGET_PANE" ]; then
      echo "$PROMPTER_TARGET_PANE"
    elif [ -n "$PROMPTER_CALLER_PANE" ]; then
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
      local cwd
      cwd=$("$TMUX_BIN" display-message -p '#{pane_current_path}' 2>/dev/null)
      echo "${cwd:-$PWD}"
    else
      echo "$PWD"
    fi
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
    # For tmux, prioritize OS clipboard over show-buffer to prevent inserting stale buffer history
    sel=$(get_clipboard_text)
    if [ -z "$sel" ] && command -v "$TMUX_BIN" &>/dev/null; then
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
          line: "Tab \($tab.label // $tab.number // "??") | \($pane.label // $pane.pane_id) (\($pane.cwd))"
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
    if [ -n "$TMUX_PANE" ] && [ "$target_pid" = "$TMUX_PANE" ] && [ -t 1 ]; then
      (sleep 0.05 && "$TMUX_BIN" send-keys "${target_opt[@]}" -l "$text") &>/dev/null &
    else
      "$TMUX_BIN" send-keys "${target_opt[@]}" -l "$text" 2>/dev/null
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
    "$TMUX_BIN" send-keys "${target_opt[@]}" -l "$text" 2>/dev/null
    "$TMUX_BIN" send-keys "${target_opt[@]}" Enter 2>/dev/null
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
  # Guard against slugs consisting solely of dots
  slug=$(printf '%s' "$slug" | sed -E 's/^\.+$//')
  if [ -z "$slug" ]; then
    slug="template"
  fi
  echo "$slug"
}

# Safe newline decoder: decodes only literal '\n' to actual newlines without touching other escapes
decode_literal_newlines() {
  local str="$1"
  if command -v python3 &>/dev/null; then
    printf '%s' "$str" | python3 -c "import sys; print(sys.stdin.read().replace(r'\n', '\n'), end='')"
  else
    printf '%s' "$str" | awk '{
      gsub(/\\n/, "\n")
      print
    }'
  fi
}

# Migrate legacy templates.txt to templates/*.md and backup to templates.txt.bak
migrate_legacy_templates() {
  if [ -f "$LEGACY_TEMPLATES_FILE" ]; then
    mkdir -p "$TEMPLATES_DIR" 2>/dev/null || true
    while IFS= read -r line || [ -n "$line" ]; do
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

  cat << 'EOF' > "${TEMPLATES_DIR}/ask-custom-question.md"
# Ask Custom Question
{{input}}
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
    first_line=$(head -n 1 "$file")
    if [[ "$first_line" =~ ^#[[:space:]]*(.+) ]]; then
      title="${BASH_REMATCH[1]}"
      body=$(sed '1d' "$file" | awk 'NF {found=1} found {print}')
    else
      title="$(basename "$file" .md)"
      body="$(cat "$file")"
    fi
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
      local clean_disp
      clean_disp=$(echo "$line" | sed 's/\\n/ /g' | cut -c1-30)
      printf '📜 %s...\t%s\n' "$clean_disp" "$line"
    done < "$HISTORY_FILE"
  fi
}

# Save prompt to history file (limit to 50 items, remove duplicate)
save_to_history() {
  local text="$1"
  local escaped_text
  escaped_text=$(printf '%s' "$text" | awk 'BEGIN {ORS="\\n"} {print}')
  escaped_text=${escaped_text%\\n}
  
  # Skip saving if the text is empty or contains only whitespace/newlines
  local check_content
  check_content=$(printf '%s' "$escaped_text" | sed -E 's/[[:space:]]|\\n//g')
  if [ -n "$check_content" ]; then
    mkdir -p "$(dirname "$HISTORY_FILE")"
    # Write new item and append existing items excluding duplicates atomically
    if [ -f "$HISTORY_FILE" ]; then
      (echo "$escaped_text"; grep -vxF "$escaped_text" "$HISTORY_FILE" 2>/dev/null || true) | head -n 50 > "${HISTORY_FILE}.tmp"
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

# Resolve all placeholders
resolve_placeholders() {
  local prompt="$1"
  local is_preview="$2" # "true" or "false"

  # 1. Interactive variables {{var:name}} (Resolved first to prevent parsing variables inside expanded code/diffs)
  local vars
  vars=$(echo "$prompt" | grep -oE "\{\{var:[a-zA-Z0-9_]+\}\}" | sort -u)
  for v in $vars; do
    local var_name
    var_name=$(echo "$v" | sed -E 's/\{\{var:([a-zA-Z0-9_]+)\}\}/\1/')
    if [ "$is_preview" == "true" ]; then
      prompt=$(safe_replace "$prompt" "$v" "[Enter value for $var_name]")
    else
      local cmd
      cmd=$(get_var_cmd "$var_name")
      local user_val=""
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
      prompt=$(safe_replace "$prompt" "$v" "$user_val")
    fi
  done

  # 2. {{input}} (Resolved early to avoid parsing inside expanded contents)
  if [[ "$prompt" == *"{{input}}"* ]]; then
    if [ "$is_preview" == "true" ]; then
      prompt=$(safe_replace "$prompt" "{{input}}" "[Your custom input]")
    else
      echo "Enter your custom question/prompt (press Ctrl+D when finished):" >&2
      local user_input
      user_input=$(cat)
      prompt=$(safe_replace "$prompt" "{{input}}" "$user_input")
    fi
  fi

  # 3. {{selected}}
  if [[ "$prompt" == *"{{selected}}"* ]]; then
    prompt=$(safe_replace "$prompt" "{{selected}}" "$SELECTED_TEXT")
  fi

  # 4. Git placeholders
  if [[ "$prompt" == *"{{git_diff:staged}}"* ]]; then
    if [ "$is_preview" == "true" ]; then
      local diff_val
      diff_val=$(safe_git diff --cached 2>/dev/null | head -n 25)
      if [ -n "$diff_val" ]; then
        if [ "$(safe_git diff --cached 2>/dev/null | wc -l)" -gt 25 ]; then
          diff_val="${diff_val}\n...(truncated for preview)"
        fi
      else
        diff_val="No staged git changes"
      fi
      prompt=$(safe_replace "$prompt" "{{git_diff:staged}}" "$diff_val")
    else
      local diff_val
      diff_val=$(safe_git diff --cached 2>/dev/null)
      prompt=$(safe_replace "$prompt" "{{git_diff:staged}}" "$diff_val")
    fi
  fi

  if [[ "$prompt" == *"{{git_diff}}"* ]]; then
    if [ "$is_preview" == "true" ]; then
      local diff_val
      diff_val=$(safe_git diff 2>/dev/null | head -n 25)
      if [ -n "$diff_val" ]; then
        if [ "$(safe_git diff 2>/dev/null | wc -l)" -gt 25 ]; then
          diff_val="${diff_val}\n...(truncated for preview)"
        fi
      else
        diff_val="No git changes"
      fi
      prompt=$(safe_replace "$prompt" "{{git_diff}}" "$diff_val")
    else
      local diff_val
      diff_val=$(safe_git diff 2>/dev/null)
      prompt=$(safe_replace "$prompt" "{{git_diff}}" "$diff_val")
    fi
  fi

  if [[ "$prompt" == *"{{git_status}}"* ]]; then
    local status_val
    status_val=$(safe_git status -s 2>/dev/null || echo "Not a git repo")
    prompt=$(safe_replace "$prompt" "{{git_status}}" "$status_val")
  fi

  if [[ "$prompt" == *"{{git_branch}}"* ]]; then
    local branch_val
    branch_val=$(safe_git branch --show-current 2>/dev/null || echo "no-branch")
    prompt=$(safe_replace "$prompt" "{{git_branch}}" "$branch_val")
  fi

  # 5. Scrollback context
  if [[ "$prompt" == *"{{pane_logs:errors}}"* ]]; then
    if [ "$is_preview" == "true" ]; then
      prompt=$(safe_replace "$prompt" "{{pane_logs:errors}}" "[Target pane logs (Errors only)]")
    else
      local logs
      logs=$(mux_read_pane_logs "$TARGET_PANE_ID" 100)
      logs=$(echo "$logs" | sed -E 's/\x1B\[[0-9;]*[a-zA-Z]//g')
      local filtered_logs
      filtered_logs=$(echo "$logs" | grep -i -B 3 -A 3 -E "error|fail|exception|fatal|panic")
      if [ -z "$filtered_logs" ]; then
        filtered_logs="No errors found in the last 100 lines of logs."
      fi
      prompt=$(safe_replace "$prompt" "{{pane_logs:errors}}" "$filtered_logs")
    fi
  fi

  if [[ "$prompt" == *"{{pane_logs}}"* ]]; then
    if [ "$is_preview" == "true" ]; then
      prompt=$(safe_replace "$prompt" "{{pane_logs}}" "[Target pane logs (last 100 lines)]")
    else
      local logs
      logs=$(mux_read_pane_logs "$TARGET_PANE_ID" 100)
      logs=$(echo "$logs" | sed -E 's/\x1B\[[0-9;]*[a-zA-Z]//g')
      prompt=$(safe_replace "$prompt" "{{pane_logs}}" "$logs")
    fi
  fi

  if [[ "$prompt" == *"{{last_command}}"* ]]; then
    if [ "$is_preview" == "true" ]; then
      prompt=$(safe_replace "$prompt" "{{last_command}}" "[Last executed command]")
    else
      local logs
      logs=$(mux_read_pane_logs "$TARGET_PANE_ID" 100)
      logs=$(echo "$logs" | sed -E 's/\x1B\][^\x07]*\x07//g; s/\x1B\[[0-9;]*[a-zA-Z]//g; s/\x1B[()][A-Z0-9]//g')
      local last_cmd=""
      # shellcheck disable=SC2016
      local prompt_symbols='(\$([[:space:]]+|$)|[%#\>❯➜▶▲│|])'
      
      while IFS= read -r line || [ -n "$line" ]; do
        [[ "$line" =~ ^[[:space:]]*$ ]] && continue
        
        # 1. Strip right-prompt (RPROMPT / timestamps) after multi-spaces
        local line_clean
        line_clean=$(echo "$line" | sed -E 's/[[:space:]]{2,}.*$//')
        
        local cmd_candidate=""
        # Case A: Standard prompt terminator ($ or % or # or ❯ or ▶) with trailing space
        if echo "$line_clean" | grep -q -E "(\\\$|%|#|❯|▶)[[:space:]]+"; then
          cmd_candidate=$(echo "$line_clean" | sed -E "s/^.*(\\\$|%|#|❯|▶)[[:space:]]+//")
        # Case B: oh-my-zsh style: ➜  dir git:(main) ✗ cmd
        elif echo "$line_clean" | grep -q -E "^➜[[:space:]]+.*git:\([^)]+\)[[:space:]]*[^[:space:]]*[[:space:]]+"; then
          cmd_candidate=$(echo "$line_clean" | sed -E "s/^➜[[:space:]]+.*git:\([^)]+\)[[:space:]]*[^[:space:]]*[[:space:]]+//")
        elif echo "$line_clean" | grep -q -E "^➜[[:space:]]+"; then
          cmd_candidate=$(echo "$line_clean" | sed -E "s/^➜[[:space:]]+[^[:space:]]+[[:space:]]+//")
        fi
        cmd_candidate=$(echo "$cmd_candidate" | sed -E 's/^[[:space:]]+|[[:space:]]+$//g')
        
        if [ -n "$cmd_candidate" ]; then
          last_cmd="$cmd_candidate"
          break
        fi
      done <<< "$(echo "$logs" | tail -n 50 | awk '{a[i++]=$0} END {for (j=i-1; j>=0; j--) print a[j]}')"

      if [ -n "$last_cmd" ]; then
        prompt=$(safe_replace "$prompt" "{{last_command}}" "$last_cmd")
      else
        echo "Could not detect last command automatically." >&2
        echo "Enter the command manually (press Enter):" >&2
        read -r manual_cmd
        prompt=$(safe_replace "$prompt" "{{last_command}}" "$manual_cmd")
      fi
    fi
  fi

  # 6. Cross-pane referencing & Broadcast target
  if [[ "$prompt" == *"{{panes:choose}}"* ]]; then
    if [ "$is_preview" == "true" ]; then
      prompt=$(safe_replace "$prompt" "{{panes:choose}}" "[Selected Broadcast Panes]")
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
              pid=$(echo "$line" | grep -oE "(%[0-9]+|surface:[a-zA-Z0-9_-]+|[a-zA-Z0-9_-]+:p[a-zA-Z0-9_-]+)" | head -n 1)
            fi
            if [ -z "$pid" ]; then
              pid=$(echo "$line" | awk -F'|' '{print $2}' | sed 's/^[[:space:]]*//;s/[[:space:]]*$//' | awk '{print $1}')
            fi
            if [ -z "$pid" ]; then
              pid=$(echo "$line" | awk -F'|' '{print $1}' | sed 's/^[[:space:]]*//;s/[[:space:]]*$//;s/^Surface[[:space:]]*//')
            fi
            [ -n "$pid" ] && TARGET_PANES+=("$pid") && pane_labels="${pane_labels}${pid} "
          done <<< "$selected_panes_lines"
          prompt=$(safe_replace "$prompt" "{{panes:choose}}" "${pane_labels}")
        else
          echo "Cancelled pane selection." >&2
          exit 0
        fi
      else
        echo "No other panes found." >&2
        prompt=$(safe_replace "$prompt" "{{panes:choose}}" "No other panes")
      fi
    fi
  fi

  if [[ "$prompt" == *"{{pane:choose}}"* ]]; then
    if [ "$is_preview" == "true" ]; then
      prompt=$(safe_replace "$prompt" "{{pane:choose}}" "[Content of selected pane]")
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
            selected_pane_id=$(echo "$selected_pane_line" | grep -oE "(%[0-9]+|surface:[a-zA-Z0-9_-]+|[a-zA-Z0-9_-]+:p[a-zA-Z0-9_-]+)" | head -n 1)
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
          prompt=$(safe_replace "$prompt" "{{pane:choose}}" "$imported_logs")
          TARGET_PANES=("$selected_pane_id")
        else
          echo "Cancelled pane selection." >&2
          exit 0
        fi
      else
        echo "No other panes found." >&2
        prompt=$(safe_replace "$prompt" "{{pane:choose}}" "No other panes")
      fi
    fi
  fi

  # 7. Smart File truncation {{file:lines=START-END}}
  if [[ "$prompt" =~ \{\{file:lines=([0-9]+)-([0-9]+)\}\} ]]; then
    local start_line="${BASH_REMATCH[1]}"
    local end_line="${BASH_REMATCH[2]}"
    
    if [ "$is_preview" == "true" ]; then
      prompt=$(safe_replace "$prompt" "{{file:lines=${start_line}-${end_line}}}" "[Content of selected file (lines ${start_line}-${end_line})]")
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
        file_path=$(find . -maxdepth 3 -type f -not -path '*/.*' 2>/dev/null | sed 's|^\./||' | fzf --layout=reverse --header="Select a file to insert (lines ${start_line}-${end_line}):")
      fi
      
      if [ -n "$file_path" ] && [ -f "$file_path" ]; then
        local file_content
        file_content=$(sed -n "${start_line},${end_line}p" "$file_path")
        prompt=$(safe_replace "$prompt" "{{file:lines=${start_line}-${end_line}}}" "$file_content")
      else
        echo "Cancelled file selection." >&2
        exit 0
      fi
    fi
  fi

  # Legacy File placeholder
  if [[ "$prompt" == *"{{file}}"* ]]; then
    if [ "$is_preview" == "true" ]; then
      prompt=$(safe_replace "$prompt" "{{file}}" "[Content of selected file]")
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
        file_path=$(find . -maxdepth 3 -type f -not -path '*/.*' 2>/dev/null | sed 's|^\./||' | fzf --layout=reverse --header="Select a file to insert:")
      fi
      
      if [ -n "$file_path" ] && [ -f "$file_path" ]; then
        local file_content
        file_content=$(cat "$file_path")
        prompt=$(safe_replace "$prompt" "{{file}}" "$file_content")
      else
        echo "Cancelled file selection." >&2
        exit 0
      fi
    fi
  fi

  # File Path placeholder {{file_path}}, {{filepath}}, {{file:path}}
  if [[ "$prompt" == *"{{file_path}}"* ]] || [[ "$prompt" == *"{{filepath}}"* ]] || [[ "$prompt" == *"{{file:path}}"* ]]; then
    if [ "$is_preview" == "true" ]; then
      prompt=$(safe_replace "$prompt" "{{file_path}}" "[Path of selected file]")
      prompt=$(safe_replace "$prompt" "{{filepath}}" "[Path of selected file]")
      prompt=$(safe_replace "$prompt" "{{file:path}}" "[Path of selected file]")
    else
      local file_path=""
      if safe_git rev-parse --is-inside-work-tree &>/dev/null; then
        local git_root
        git_root=$(safe_git rev-parse --show-toplevel)
        file_path=$(cd "$git_root" && (safe_git status -s | cut -c4-; safe_git ls-files) | sort -u | fzf --layout=reverse --header="Select a file to insert path:")
      else
        file_path=$(find . -maxdepth 3 -type f -not -path '*/.*' 2>/dev/null | sed 's|^\./||' | fzf --layout=reverse --header="Select a file to insert path:")
      fi
      
      if [ -n "$file_path" ]; then
        prompt=$(safe_replace "$prompt" "{{file_path}}" "$file_path")
        prompt=$(safe_replace "$prompt" "{{filepath}}" "$file_path")
        prompt=$(safe_replace "$prompt" "{{file:path}}" "$file_path")
      else
        echo "Cancelled file selection." >&2
        exit 0
      fi
    fi
  fi

  # 8. {{error}}
  if [[ "$prompt" == *"{{error}}"* ]]; then
    if [ "$is_preview" == "true" ]; then
      prompt=$(safe_replace "$prompt" "{{error}}" "[Recent target pane error logs]")
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
        prompt=$(safe_replace "$prompt" "{{error}}" "$err_info")
      else
        echo "Could not read terminal output automatically." >&2
        echo "Enter the error message manually (press Ctrl+D when finished):" >&2
        local manual_error
        manual_error=$(cat)
        prompt=$(safe_replace "$prompt" "{{error}}" "$manual_error")
      fi
    fi
  fi

  RESOLVED_PROMPT="$prompt"
}

# --- Handle Option List Modes (for fzf reload) ---
if [ "$1" == "--list-templates" ]; then
  load_templates
  for title in "${TEMPLATES_TITLES[@]}"; do
    echo "$title"
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
    echo "$title"
  done
  echo "🔧 Edit Templates"
  exit 0
fi

# --- Handle Preview Mode ---
if [ "$1" == "--preview-only" ]; then
  SELECTED_TITLE="$2"
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

  # Run fzf with preview panel enabled and dynamic reload binding
  # Default view: Templates
  SELECTED_OPTION=$(bash "$SCRIPT_PATH" --list-templates | sed '/^$/d' | fzf \
    --header="[Ctrl-T] Templates  |  [Ctrl-R] History  |  [Ctrl-A] All Options" \
    --prompt="Templates> " \
    --layout=reverse \
    --delimiter=$'\t' \
    --with-nth=1 \
    --preview="bash \"$SCRIPT_PATH\" --preview-only {q}" \
    --preview-window=right:50%:wrap \
    --bind "ctrl-r:reload(bash \"$SCRIPT_PATH\" --list-history)+change-prompt(History> )" \
    --bind "ctrl-t:reload(bash \"$SCRIPT_PATH\" --list-templates)+change-prompt(Templates> )" \
    --bind "ctrl-a:reload(bash \"$SCRIPT_PATH\" --list-all)+change-prompt(All> )")

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
    MY_EDITOR="${EDITOR:-nano}"
    if ! command -v "$MY_EDITOR" &>/dev/null; then
      MY_EDITOR="vi"
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
      "$MY_EDITOR" "$target_edit_file"
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

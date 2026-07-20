#!/usr/bin/env bash
# Mux Prompter - Fuzzy-pick and inject context-aware prompts into Herdr panes
# SPDX-License-Identifier: MIT

# Absolute path of this script to allow self-invocation after directory changes
SCRIPT_PATH="$(cd "$(dirname "$0")" && pwd)/$(basename "$0")"

# Herdr bin path
HERDR_BIN="${HERDR_BIN_PATH:-herdr}"

# Check dependencies
if ! command -v jq &> /dev/null; then
  echo "Error: 'jq' is required to run this plugin." >&2
  read -r -p "Press Enter to exit..."
  exit 1
fi

if ! command -v fzf &> /dev/null; then
  echo "Error: 'fzf' is required to run this plugin." >&2
  read -r -p "Press Enter to exit..."
  exit 1
fi

# Configuration directories
CONFIG_DIR="${HERDR_PLUGIN_CONFIG_DIR}"
TEMPLATES_FILE="${CONFIG_DIR}/templates.txt"
HISTORY_FILE="${CONFIG_DIR}/prompter_history.txt"

# Default templates
DEFAULT_TEMPLATES=(
  "Fix Terminal Error|I ran \`{{last_command}}\` and encountered this error:\n\n\`\`\`\n{{error}}\n\`\`\`\nPlease analyze and fix this."
  "Review Other Pane Logs|Please analyze the logs from the selected pane:\n\n\`\`\`\n{{pane:choose}}\n\`\`\`"
  "Refactor Selected Code|Please refactor this code to improve readability and performance:\n\n\`\`\`\n{{selected}}\n\`\`\`"
  "Review Whole File|Please review the contents of this file for potential issues:\n\n\`\`\`\n{{file}}\n\`\`\`"
  "Review Git Changes|Please review the following git changes:\n\n\`\`\`\n{{git_diff}}\n\`\`\`"
  "Review Staged Git Changes|Please review only the staged git changes:\n\n\`\`\`\n{{git_diff:staged}}\n\`\`\`"
  "Explain Error Logs|Help me debug these recent error logs:\n\n\`\`\`\n{{pane_logs:errors}}\n\`\`\`"
  "Deploy Component|Deploying {{var:component}} to {{var:environment}}."
  "Broadcast Command|{{panes:choose}} -> Send command: {{input}}"
  "Ask Custom Question|{{input}}"
  "!Run Git Status|git status"
  "!Run Tests|npm test"
)

# Load templates from file or initialize defaults
load_templates() {
  TEMPLATES=()
  if [ -f "$TEMPLATES_FILE" ]; then
    while IFS= read -r line || [ -n "$line" ]; do
      # Skip empty lines or comments
      [[ "$line" =~ ^[[:space:]]*$ ]] && continue
      [[ "$line" =~ ^# ]] && continue
      # Skip custom variable commands (starting with $)
      [[ "$line" =~ ^\$ ]] && continue
      TEMPLATES+=("$line")
    done < "$TEMPLATES_FILE"
  else
    # Save default templates to file for future user edits
    if [ -n "$CONFIG_DIR" ] && [ -d "$CONFIG_DIR" ]; then
      mkdir -p "$CONFIG_DIR"
      {
        for t in "${DEFAULT_TEMPLATES[@]}"; do
          echo "$t"
        done
        # Save a sample custom variable definition to templates.txt as comment/example
        echo ""
        echo "# Example custom variable candidate generators:"
        echo "# $ branch: git branch --format=\"%(refname:short)\""
      } >> "$TEMPLATES_FILE"
    fi
    TEMPLATES=("${DEFAULT_TEMPLATES[@]}")
  fi
}

# Resolve candidate generator command for custom variables
get_var_cmd() {
  local target_var="$1"
  if [ -f "$TEMPLATES_FILE" ]; then
    local cmd_line
    cmd_line=$(grep -E '^[$][[:space:]]*'"${target_var}"'[[:space:]]*:' "$TEMPLATES_FILE" | head -n 1)
    if [ -n "$cmd_line" ]; then
      echo "$cmd_line" | cut -d':' -f2- | sed 's/^[[:space:]]*//'
      return 0
    fi
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
      printf '📜 %s... | %s\n' "$clean_disp" "$line"
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
    local temp_file
    temp_file=$(mktemp)
    
    # Write new item first
    echo "$escaped_text" > "$temp_file"
    
    # Append existing history items excluding the duplicate
    if [ -f "$HISTORY_FILE" ]; then
      grep -vxF "$escaped_text" "$HISTORY_FILE" >> "$temp_file" 2>/dev/null || true
    fi
    
    # Keep only the first 50 lines
    head -n 50 "$temp_file" > "$HISTORY_FILE"
    rm -f "$temp_file"
  fi
}

# Get text from clipboard as fallback for selected text
get_clipboard_text() {
  if command -v pbpaste &>/dev/null; then
    pbpaste
  elif command -v xclip &>/dev/null; then
    xclip -selection clipboard -o 2>/dev/null
  elif command -v xsel &>/dev/null; then
    xsel --clipboard --output 2>/dev/null
  fi
}

# Resolve all placeholders
resolve_placeholders() {
  local prompt="$1"
  local is_preview="$2" # "true" or "false"

  # 1. {{selected}}
  if [[ "$prompt" == *"{{selected}}"* ]]; then
    prompt="${prompt//\{\{selected\}\}/$SELECTED_TEXT}"
  fi

  # 2. Git placeholders
  if [[ "$prompt" == *"{{git_diff:staged}}"* ]]; then
    if [ "$is_preview" == "true" ]; then
      local diff_val
      diff_val=$(git diff --cached 2>/dev/null | head -n 25)
      if [ -n "$diff_val" ]; then
        if [ "$(git diff --cached 2>/dev/null | wc -l)" -gt 25 ]; then
          diff_val="${diff_val}\n...(truncated for preview)"
        fi
      else
        diff_val="No staged git changes"
      fi
      prompt="${prompt//\{\{git_diff:staged\}\}/$diff_val}"
    else
      local diff_val
      diff_val=$(git diff --cached 2>/dev/null)
      prompt="${prompt//\{\{git_diff:staged\}\}/$diff_val}"
    fi
  fi

  if [[ "$prompt" == *"{{git_diff}}"* ]]; then
    if [ "$is_preview" == "true" ]; then
      local diff_val
      diff_val=$(git diff 2>/dev/null | head -n 25)
      if [ -n "$diff_val" ]; then
        if [ "$(git diff 2>/dev/null | wc -l)" -gt 25 ]; then
          diff_val="${diff_val}\n...(truncated for preview)"
        fi
      else
        diff_val="No git changes"
      fi
      prompt="${prompt//\{\{git_diff\}\}/$diff_val}"
    else
      local diff_val
      diff_val=$(git diff 2>/dev/null)
      prompt="${prompt//\{\{git_diff\}\}/$diff_val}"
    fi
  fi

  if [[ "$prompt" == *"{{git_status}}"* ]]; then
    local status_val
    status_val=$(git status -s 2>/dev/null || echo "Not a git repo")
    prompt="${prompt//\{\{git_status\}\}/$status_val}"
  fi

  if [[ "$prompt" == *"{{git_branch}}"* ]]; then
    local branch_val
    branch_val=$(git branch --show-current 2>/dev/null || echo "no-branch")
    prompt="${prompt//\{\{git_branch\}\}/$branch_val}"
  fi

  # 3. Scrollback context
  if [[ "$prompt" == *"{{pane_logs:errors}}"* ]]; then
    if [ "$is_preview" == "true" ]; then
      prompt="${prompt//\{\{pane_logs:errors\}\}/[Target pane logs (Errors only)]}"
    else
      local logs
      logs=$("$HERDR_BIN" pane read "$TARGET_PANE_ID" --lines 100 2>/dev/null)
      logs=$(echo "$logs" | sed -E 's/\x1B\[[0-9;]*[a-zA-Z]//g')
      local filtered_logs
      filtered_logs=$(echo "$logs" | grep -i -B 3 -A 3 -E "error|fail|exception|fatal|panic")
      if [ -z "$filtered_logs" ]; then
        filtered_logs="No errors found in the last 100 lines of logs."
      fi
      prompt="${prompt//\{\{pane_logs:errors\}\}/$filtered_logs}"
    fi
  fi

  if [[ "$prompt" == *"{{pane_logs}}"* ]]; then
    if [ "$is_preview" == "true" ]; then
      prompt="${prompt//\{\{pane_logs\}\}/[Target pane logs (last 100 lines)]}"
    else
      local logs
      logs=$("$HERDR_BIN" pane read "$TARGET_PANE_ID" --lines 100 2>/dev/null)
      logs=$(echo "$logs" | sed -E 's/\x1B\[[0-9;]*[a-zA-Z]//g')
      prompt="${prompt//\{\{pane_logs\}\}/$logs}"
    fi
  fi

  if [[ "$prompt" == *"{{last_command}}"* ]]; then
    if [ "$is_preview" == "true" ]; then
      prompt="${prompt//\{\{last_command\}\}/[Last executed command]}"
    else
      local logs
      logs=$("$HERDR_BIN" pane read "$TARGET_PANE_ID" --lines 100 2>/dev/null)
      logs=$(echo "$logs" | sed -E 's/\x1B\][^\x07]*\x07//g; s/\x1B\[[0-9;]*[a-zA-Z]//g; s/\x1B[()][A-Z0-9]//g')
      local last_cmd=""
      # shellcheck disable=SC2016
      local prompt_symbols='(\$([[:space:]]+|$)|[%#\>❯➜▶▲│|])'
      
      while IFS= read -r line || [ -n "$line" ]; do
        [[ "$line" =~ ^[[:space:]]*$ ]] && continue
        
        # Check if line contains any prompt / segment glyph
        if echo "$line" | grep -q -E "$prompt_symbols"; then
          # 1. Strip right-prompt (RPROMPT / timestamps) after multi-spaces
          local line_clean
          line_clean=$(echo "$line" | sed -E 's/[[:space:]]{2,}.*$//')
          
          # 2. Extract content after the absolute LAST prompt/segment glyph
          local cmd_candidate
          cmd_candidate=$(echo "$line_clean" | sed -E "s/.*${prompt_symbols}[[:space:]]*//")
          cmd_candidate=$(echo "$cmd_candidate" | sed -E 's/^[[:space:]]+|[[:space:]]+$//g')
          
          if [ -n "$cmd_candidate" ]; then
            last_cmd="$cmd_candidate"
            break
          fi
        fi
      done <<< "$(echo "$logs" | tail -n 50 | awk '{a[i++]=$0} END {for (j=i-1; j>=0; j--) print a[j]}')"

      if [ -n "$last_cmd" ]; then
        prompt="${prompt//\{\{last_command\}\}/$last_cmd}"
      else
        echo "Could not detect last command automatically." >&2
        echo "Enter the command manually (press Enter):" >&2
        read -r manual_cmd
        prompt="${prompt//\{\{last_command\}\}/$manual_cmd}"
      fi
    fi
  fi

  # 4. Cross-pane referencing & Broadcast target
  if [[ "$prompt" == *"{{panes:choose}}"* ]]; then
    if [ "$is_preview" == "true" ]; then
      prompt="${prompt//\{\{panes:choose\}\}/[Selected Broadcast Panes]}"
    else
      local panes_json
      panes_json=$("$HERDR_BIN" pane list 2>/dev/null)
      if [ -n "$panes_json" ]; then
        local tabs_json
        tabs_json=$("$HERDR_BIN" tab list 2>/dev/null || echo "{}")
        local pane_options
        pane_options=$(echo "$panes_json" | jq -r --argjson tabs_obj "$tabs_json" '
          [.result.panes[] |
          select(.pane_id != "'"$TARGET_PANE_ID"'") |
          . as $pane |
          (($tabs_obj.result.tabs[]? | select(.tab_id == $pane.tab_id)) // {}) as $tab |
          {
            tab_num: ($tab.number // 999),
            pane_id: $pane.pane_id,
            line: "Tab \($tab.label // $tab.number // "??") | \($pane.label // $pane.pane_id) (\($pane.cwd))"
          }] | sort_by(.tab_num, .pane_id)[].line
        ' 2>/dev/null)
        if [ -n "$pane_options" ]; then
          # Multi-selection fzf
          local selected_panes_lines
          selected_panes_lines=$(echo "$pane_options" | fzf --layout=reverse -m --header="Select target panes for broadcast (Tab to select multiple, Enter to confirm):")
          if [ -n "$selected_panes_lines" ]; then
            TARGET_PANES=()
            local pane_labels=""
            while read -r line; do
              [ -z "$line" ] && continue
              local pid
              pid=$(echo "$line" | grep -oE "[a-zA-Z0-9_-]+:p[a-zA-Z0-9_-]+" | head -n 1)
              [ -n "$pid" ] && TARGET_PANES+=("$pid") && pane_labels="${pane_labels}${pid} "
            done <<< "$selected_panes_lines"
            prompt="${prompt//\{\{panes:choose\}\}/${pane_labels}}"
          else
            echo "Cancelled pane selection." >&2
            exit 0
          fi
        else
          echo "No other panes found." >&2
          prompt="${prompt//\{\{panes:choose\}\}/No other panes}"
        fi
      else
        prompt="${prompt//\{\{panes:choose\}\}/[Failed to list panes]}"
      fi
    fi
  fi

  if [[ "$prompt" == *"{{pane:choose}}"* ]]; then
    if [ "$is_preview" == "true" ]; then
      prompt="${prompt//\{\{pane:choose\}\}/[Content of selected pane]}"
    else
      local panes_json
      panes_json=$("$HERDR_BIN" pane list 2>/dev/null)
      if [ -n "$panes_json" ]; then
        local tabs_json
        tabs_json=$("$HERDR_BIN" tab list 2>/dev/null || echo "{}")
        local pane_options
        pane_options=$(echo "$panes_json" | jq -r --argjson tabs_obj "$tabs_json" '
          [.result.panes[] |
          select(.pane_id != "'"$TARGET_PANE_ID"'") |
          . as $pane |
          (($tabs_obj.result.tabs[]? | select(.tab_id == $pane.tab_id)) // {}) as $tab |
          {
            tab_num: ($tab.number // 999),
            pane_id: $pane.pane_id,
            line: "Tab \($tab.label // $tab.number // "??") | \($pane.label // $pane.pane_id) (\($pane.cwd))"
          }] | sort_by(.tab_num, .pane_id)[].line
        ' 2>/dev/null)
        if [ -n "$pane_options" ]; then
          local selected_pane_line
          selected_pane_line=$(echo "$pane_options" | fzf --layout=reverse --header="Select a pane to import logs from:")
          if [ -n "$selected_pane_line" ]; then
            local selected_pane_id
            selected_pane_id=$(echo "$selected_pane_line" | grep -oE "[a-zA-Z0-9_-]+:p[a-zA-Z0-9_-]+" | head -n 1)
            local imported_logs
            imported_logs=$("$HERDR_BIN" pane read "$selected_pane_id" --lines 100 2>/dev/null)
            imported_logs=$(echo "$imported_logs" | sed -E 's/\x1B\[[0-9;]*[a-zA-Z]//g')
            prompt="${prompt//\{\{pane:choose\}\}/$imported_logs}"
          else
            echo "Cancelled pane selection." >&2
            exit 0
          fi
        else
          echo "No other panes found." >&2
          prompt="${prompt//\{\{pane:choose\}\}/No other panes}"
        fi
      else
        prompt="${prompt//\{\{pane:choose\}\}/[Failed to list panes]}"
      fi
    fi
  fi

  # 5. Interactive variables {{var:name}}
  local vars
  vars=$(echo "$prompt" | grep -oE "\{\{var:[a-zA-Z0-9_]+\}\}" | sort -u)
  for v in $vars; do
    local var_name
    var_name=$(echo "$v" | sed -E 's/\{\{var:([a-zA-Z0-9_]+)\}\}/\1/')
    if [ "$is_preview" == "true" ]; then
      prompt="${prompt//$v/[Enter value for $var_name]}"
    else
      local cmd
      cmd=$(get_var_cmd "$var_name")
      local user_val=""
      if [ -n "$cmd" ]; then
        local candidates
        candidates=$(eval "$cmd" 2>/dev/null)
        if [ -n "$candidates" ]; then
          user_val=$(echo "$candidates" | fzf --layout=reverse --header="Select value for $var_name:")
        fi
      fi
      if [ -z "$user_val" ]; then
        echo -n "Enter value for [$var_name]: " >&2
        read -r user_val
      fi
      prompt="${prompt//$v/$user_val}"
    fi
  done

  # 6. Smart File truncation {{file:lines=START-END}}
  if [[ "$prompt" =~ \{\{file:lines=([0-9]+)-([0-9]+)\}\} ]]; then
    local start_line="${BASH_REMATCH[1]}"
    local end_line="${BASH_REMATCH[2]}"
    local placeholder="\{\{file:lines=${start_line}-${end_line}\}\}"
    
    if [ "$is_preview" == "true" ]; then
      prompt=$(echo -e "$prompt" | sed "s/${placeholder}/[Content of selected file (lines ${start_line}-${end_line})]/g")
    else
      local file_path=""
      if git rev-parse --is-inside-work-tree &>/dev/null; then
        local git_root
        git_root=$(git rev-parse --show-toplevel)
        file_path=$(cd "$git_root" && (git status -s | cut -c4-; git ls-files) | sort -u | fzf --layout=reverse --header="Select a file to insert (lines ${start_line}-${end_line}):")
        if [ -n "$file_path" ]; then
          file_path="${git_root}/${file_path}"
        fi
      else
        file_path=$(find . -maxdepth 3 -type f -not -path '*/.*' 2>/dev/null | sed 's|^\./||' | fzf --layout=reverse --header="Select a file to insert (lines ${start_line}-${end_line}):")
      fi
      
      if [ -n "$file_path" ] && [ -f "$file_path" ]; then
        local file_content
        file_content=$(sed -n "${start_line},${end_line}p" "$file_path")
        # Use sed/awk or python to safely replace template, shell variable substitution can break if content is large
        # But for simpler shell script, bash replacement is fine if we use an intermediate variable
        # We need to escape special characters in the text
        prompt="${prompt//\{\{file:lines=${start_line}-${end_line}\}\}/$file_content}"
      else
        echo "Cancelled file selection." >&2
        exit 0
      fi
    fi
  fi

  # Legacy File placeholder
  if [[ "$prompt" == *"{{file}}"* ]]; then
    if [ "$is_preview" == "true" ]; then
      prompt="${prompt//\{\{file\}\}/[Content of selected file]}"
    else
      local file_path=""
      if git rev-parse --is-inside-work-tree &>/dev/null; then
        local git_root
        git_root=$(git rev-parse --show-toplevel)
        file_path=$(cd "$git_root" && (git status -s | cut -c4-; git ls-files) | sort -u | fzf --layout=reverse --header="Select a file to insert (Git Root: $(basename "$git_root")):")
        if [ -n "$file_path" ]; then
          file_path="${git_root}/${file_path}"
        fi
      else
        file_path=$(find . -maxdepth 3 -type f -not -path '*/.*' 2>/dev/null | sed 's|^\./||' | fzf --layout=reverse --header="Select a file to insert:")
      fi
      
      if [ -n "$file_path" ] && [ -f "$file_path" ]; then
        local file_content
        file_content=$(cat "$file_path")
        prompt="${prompt//\{\{file\}\}/$file_content}"
      else
        echo "Cancelled file selection." >&2
        exit 0
      fi
    fi
  fi

  # File Path placeholder {{file_path}}, {{filepath}}, {{file:path}}
  if [[ "$prompt" == *"{{file_path}}"* ]] || [[ "$prompt" == *"{{filepath}}"* ]] || [[ "$prompt" == *"{{file:path}}"* ]]; then
    if [ "$is_preview" == "true" ]; then
      prompt="${prompt//\{\{file_path\}\}/[Path of selected file]}"
      prompt="${prompt//\{\{filepath\}\}/[Path of selected file]}"
      prompt="${prompt//\{\{file:path\}\}/[Path of selected file]}"
    else
      local file_path=""
      if git rev-parse --is-inside-work-tree &>/dev/null; then
        local git_root
        git_root=$(git rev-parse --show-toplevel)
        file_path=$(cd "$git_root" && (git status -s | cut -c4-; git ls-files) | sort -u | fzf --layout=reverse --header="Select a file to insert path:")
      else
        file_path=$(find . -maxdepth 3 -type f -not -path '*/.*' 2>/dev/null | sed 's|^\./||' | fzf --layout=reverse --header="Select a file to insert path:")
      fi
      
      if [ -n "$file_path" ]; then
        prompt="${prompt//\{\{file_path\}\}/$file_path}"
        prompt="${prompt//\{\{filepath\}\}/$file_path}"
        prompt="${prompt//\{\{file:path\}\}/$file_path}"
      else
        echo "Cancelled file selection." >&2
        exit 0
      fi
    fi
  fi

  if [[ "$prompt" == *"{{error}}"* ]]; then
    if [ "$is_preview" == "true" ]; then
      prompt="${prompt//\{\{error\}\}/[Recent target pane error logs]}"
    else
      local pane_logs
      pane_logs=$("$HERDR_BIN" pane read "$TARGET_PANE_ID" --lines 50 2>/dev/null)
      if [ -n "$pane_logs" ]; then
        local pane_logs_clean
        pane_logs_clean=$(echo "$pane_logs" | sed -E 's/\x1B\][^\x07]*\x07//g; s/\x1B\[[0-9;]*[a-zA-Z]//g; s/\x1B[()][A-Z0-9]//g')
        local err_info
        err_info=$(echo "$pane_logs_clean" | grep -i -E "error|fail|exception|fatal|panic|err:" | tail -n 15)
        if [ -z "$err_info" ]; then
          err_info="No explicit errors (error/fail/panic/exception) detected in the last 50 lines."
        fi
        prompt="${prompt//\{\{error\}\}/$err_info}"
      else
        echo "Could not read terminal output automatically." >&2
        echo "Enter the error message manually (press Ctrl+D when finished):" >&2
        local manual_error
        manual_error=$(cat)
        prompt="${prompt//\{\{error\}\}/$manual_error}"
      fi
    fi
  fi

  if [[ "$prompt" == *"{{input}}"* ]]; then
    if [ "$is_preview" == "true" ]; then
      prompt="${prompt//\{\{input\}\}/[Your custom input]}"
    else
      echo "Enter your custom question/prompt (press Ctrl+D when finished):" >&2
      local user_input
      user_input=$(cat)
      prompt="${prompt//\{\{input\}\}/$user_input}"
    fi
  fi

  echo -e "$prompt"
}

# --- Handle Option List Modes (for fzf reload) ---
if [ "$1" == "--list-templates" ]; then
  load_templates
  for t in "${TEMPLATES[@]}"; do
    echo "$t" | cut -d'|' -f1
  done
  echo "⚙️ Edit Templates"
  exit 0
fi

if [ "$1" == "--list-history" ]; then
  load_history_options
  exit 0
fi

if [ "$1" == "--list-all" ]; then
  load_history_options
  load_templates
  for t in "${TEMPLATES[@]}"; do
    echo "$t" | cut -d'|' -f1
  done
  echo "⚙️ Edit Templates"
  exit 0
fi

# --- Handle Preview Mode ---
if [ "$1" == "--preview-only" ]; then
  SELECTED_TITLE="$2"
  CONTEXT_JSON="$3"
  
  # Parse context for preview
  TARGET_PANE_ID=$(printf '%s' "$CONTEXT_JSON" | jq -r '.focused_pane_id // .focused_pane.id // empty')
  WORKSPACE_CWD=$(printf '%s' "$CONTEXT_JSON" | jq -r '.workspace_cwd // .workspace.cwd // empty')
  SELECTED_TEXT=$(printf '%s' "$CONTEXT_JSON" | jq -r '.selected_text // .selected.text // .selected // empty')
  if [ -z "$SELECTED_TEXT" ]; then
    SELECTED_TEXT=$(get_clipboard_text)
  fi
  
  if [ -n "$WORKSPACE_CWD" ] && [ -d "$WORKSPACE_CWD" ]; then
    cd "$WORKSPACE_CWD" || exit 1
  fi
  
  # Handle history item preview
  if [[ "$SELECTED_TITLE" == "📜 "* ]]; then
    # Extract the raw escaped text from behind the pipe
    escaped_history=$(printf '%s' "$SELECTED_TITLE" | cut -d'|' -f2- | sed 's/^[[:space:]]*//')
    # Decode back to preview format
    echo -e "$escaped_history"
    exit 0
  fi
  
  load_templates
  
  # Find matching template
  TEMPLATE_BODY=""
  for t in "${TEMPLATES[@]}"; do
    title=$(echo "$t" | cut -d'|' -f1)
    if [ "$title" == "$SELECTED_TITLE" ]; then
      TEMPLATE_BODY=$(echo "$t" | cut -d'|' -f2-)
      break
    fi
  done
  
  if [ -z "$TEMPLATE_BODY" ]; then
    if [ "$SELECTED_TITLE" == "⚙️ Edit Templates" ]; then
      echo "Open configuration file: $TEMPLATES_FILE"
    else
      echo "No template found."
    fi
    exit 0
  fi
  
  # Output the preview
  resolve_placeholders "$TEMPLATE_BODY" "true"
  exit 0
fi

# --- Standard Plugin Flow ---
# Parse context
TARGET_PANE_ID=$(printf '%s' "$HERDR_PLUGIN_CONTEXT_JSON" | jq -r '.focused_pane_id // .focused_pane.id // empty')
WORKSPACE_CWD=$(printf '%s' "$HERDR_PLUGIN_CONTEXT_JSON" | jq -r '.workspace_cwd // .workspace.cwd // empty')
SELECTED_TEXT=$(printf '%s' "$HERDR_PLUGIN_CONTEXT_JSON" | jq -r '.selected_text // .selected.text // .selected // empty')
if [ -z "$SELECTED_TEXT" ]; then
  SELECTED_TEXT=$(get_clipboard_text)
fi

if [ -z "$TARGET_PANE_ID" ]; then
  echo "Error: Could not resolve target pane ID from HERDR_PLUGIN_CONTEXT_JSON." >&2
  read -r -p "Press Enter to exit..."
  exit 1
fi

if [ -n "$WORKSPACE_CWD" ] && [ -d "$WORKSPACE_CWD" ]; then
  cd "$WORKSPACE_CWD" || exit 1
fi

# Target Panes initialization
TARGET_PANES=("$TARGET_PANE_ID")

load_templates

# Export variables for child fzf reload processes
export HERDR_BIN
export CONFIG_DIR
export TEMPLATES_FILE
export HISTORY_FILE
export HERDR_PLUGIN_CONTEXT_JSON
export SCRIPT_PATH

# Run fzf with preview panel enabled and dynamic reload binding
# Default view: Templates
SELECTED_OPTION=$(bash "$SCRIPT_PATH" --list-templates | sed '/^$/d' | fzf \
  --header="[Ctrl-T] Templates  |  [Ctrl-R] History  |  [Ctrl-A] All Options" \
  --prompt="Templates> " \
  --layout=reverse \
  --preview="bash \"$SCRIPT_PATH\" --preview-only {} '$HERDR_PLUGIN_CONTEXT_JSON'" \
  --preview-window=right:50%:wrap \
  --bind "ctrl-r:reload(bash \"$SCRIPT_PATH\" --list-history)+change-prompt(History> )" \
  --bind "ctrl-t:reload(bash \"$SCRIPT_PATH\" --list-templates)+change-prompt(Templates> )" \
  --bind "ctrl-a:reload(bash \"$SCRIPT_PATH\" --list-all)+change-prompt(All> )")

if [ -z "$SELECTED_OPTION" ]; then
  exit 0
fi

FINAL_PROMPT=""
EXECUTE_IMMEDIATELY=false

# Handle history selection
if [[ "$SELECTED_OPTION" == "📜 "* ]]; then
  # Extract and decode history prompt
  escaped_prompt=$(printf '%s' "$SELECTED_OPTION" | cut -d'|' -f2- | sed 's/^[[:space:]]*//')
  FINAL_PROMPT=$(echo -e "$escaped_prompt")
  # Determine if it's immediate command by checking if it starts with ! (after de-escaping)
  if [[ "$FINAL_PROMPT" == "!"* ]]; then
    EXECUTE_IMMEDIATELY=true
    FINAL_PROMPT="${FINAL_PROMPT:1}" # strip !
  fi
  
  # Re-save to push to top of history
  save_to_history "$FINAL_PROMPT"
else
  # Handle templates edit option
  if [ "$SELECTED_OPTION" == "⚙️ Edit Templates" ]; then
    MY_EDITOR="${EDITOR:-nano}"
    if ! command -v "$MY_EDITOR" &>/dev/null; then
      MY_EDITOR="vi"
    fi
    clear
    echo "Opening templates file for editing..."
    "$MY_EDITOR" "$TEMPLATES_FILE"
    exit 0
  fi

  # Check if it should be executed immediately
  if [[ "$SELECTED_OPTION" == "!"* ]]; then
    EXECUTE_IMMEDIATELY=true
  else
    EXECUTE_IMMEDIATELY=false
  fi

  # Find the matching template body
  TEMPLATE_BODY=""
  for t in "${TEMPLATES[@]}"; do
    title=$(echo "$t" | cut -d'|' -f1)
    if [ "$title" == "$SELECTED_OPTION" ]; then
      TEMPLATE_BODY=$(echo "$t" | cut -d'|' -f2-)
      break
    fi
  done

  # Resolve placeholders in execution mode
  FINAL_PROMPT=$(resolve_placeholders "$TEMPLATE_BODY" "false")
  
  # Save the finalized prompt (if not empty and not just edit action)
  if [ -n "$FINAL_PROMPT" ]; then
    # Preserve immediate execution prefix if applicable when storing history
    if [ "$EXECUTE_IMMEDIATELY" = true ]; then
      save_to_history "!${FINAL_PROMPT}"
    else
      save_to_history "$FINAL_PROMPT"
    fi
  fi
fi

# Inject into the target pane(s)
for target_pid in "${TARGET_PANES[@]}"; do
  if [ "$EXECUTE_IMMEDIATELY" = true ]; then
    echo "Executing command in pane $target_pid..."
    "$HERDR_BIN" pane run "$target_pid" "$FINAL_PROMPT"
  else
    echo "Injecting prompt into pane $target_pid..."
    "$HERDR_BIN" pane send-text "$target_pid" "$FINAL_PROMPT"
  fi
done

#!/usr/bin/env bash
# Mux Prompter - Unit / Integration Tests
# SPDX-License-Identifier: MIT

# Test script paths
TEST_DIR="$(cd "$(dirname "$0")" && pwd)"
PROMPTER_SCRIPT="$(cd "$TEST_DIR/.." && pwd)/prompter.sh"
cd "$TEST_DIR" || exit 1

# Create directories
MOCK_CONFIG_DIR="$TEST_DIR/mock_config"
MOCK_BIN_DIR="$TEST_DIR/mock_bin"
mkdir -p "$MOCK_CONFIG_DIR"
mkdir -p "$MOCK_BIN_DIR"

# Write templates file including new templates for staged diff, smart logs, and broadcast
cat << 'EOF' > "$MOCK_CONFIG_DIR/templates.txt"
Review Git Changes|Please review the following git changes:\n\n{{git_diff}}
Review Staged Git Changes|Please review only the staged git changes:\n\n{{git_diff:staged}}
Explain Logs|Here are the target pane logs:\n\n{{pane_logs}}
Explain Error Logs|Help me debug these error logs:\n\n{{pane_logs:errors}}
Analyze Last Cmd|Explain the last command output:\n\nLast command: {{last_command}}\nLogs:\n{{pane_logs}}
Cross Pane Review|Analyze the logs from the other pane:\n\n{{pane:choose}}
Custom Variable Test|Deploying {{var:service}} to {{var:env}}
$ service: echo -e "frontend\nbackend\nauth"
Analyze File|Analyzing file contents:\n\n{{file}}
Broadcast Command|{{panes:choose}} -> Send command: {{input}}
!Run Git Status|git status
EOF

# Single robust Mock fzf that handles all test stages including multicast and history
cat << 'EOF' > "$MOCK_BIN_DIR/fzf"
#!/usr/bin/env bash
args="$*"

# Case 1: Template or History selection
if [[ "$args" == *"[Ctrl-R] History"* ]] || [[ "$args" == *"Select a prompt template"* ]]; then
  case "$TEST_STAGE" in
    "git")          echo "Review Git Changes" ;;
    "staged_git")   echo "Review Staged Git Changes" ;;
    "logs")         echo "Explain Logs" ;;
    "error_logs")   echo "Explain Error Logs" ;;
    "lastcmd")      echo "Analyze Last Cmd" ;;
    "crosspane")    echo "Cross Pane Review" ;;
    "customvar")    echo "Custom Variable Test" ;;
    "file")         echo "Analyze File" ;;
    "immediate")    echo "!Run Git Status" ;;
    "broadcast")    echo "Broadcast Command" ;;
    "use_history")
      # Return a mocked history choice
      echo "📜 Hello World History... | Hello World from history"
      ;;
    *)              echo "Ask Custom Question" ;;
  esac
  exit 0
fi

# Case 2: Custom variable select (service)
if [[ "$args" == *"Select value for service:"* ]]; then
  echo "frontend"
  exit 0
fi

# Case 3: Single Pane selection
if [[ "$args" == *"Select a pane to import logs from:"* ]]; then
  echo "w2:p1 | No Label (/Users/oishik)"
  exit 0
fi

# Case 4: Multiple Panes selection (broadcast)
if [[ "$args" == *"Select target panes for broadcast"* ]]; then
  echo -e "w2:p1 | No Label (/Users/oishik)\nw2:p3 | Prompter UI (/Users/oishik/apps/herdr-prompter)"
  exit 0
fi

# Case 5: File selection
if [[ "$args" == *"Select a file to insert"* ]]; then
  echo "dummy_test_file.txt"
  exit 0
fi

# Default fallback (read from stdin and return first item)
options=()
while IFS= read -r line || [ -n "$line" ]; do
  options+=("$line")
done
for opt in "${options[@]}"; do
  clean_opt=$(echo "$opt" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')
  if [ -n "$clean_opt" ]; then
    echo "$clean_opt"
    exit 0
  fi
done
EOF
chmod +x "$MOCK_BIN_DIR/fzf"

# Mock herdr CLI
cat << 'EOF' > "$MOCK_BIN_DIR/herdr"
#!/usr/bin/env bash
# Check if pane read is requested
if [ "$1" == "pane" ] && [ "$2" == "read" ]; then
  # Return dummy log output containing prompt and command with errors
  echo -e "zsh\n\$ npm run dev\n[INFO] server started on port 3000\n[ERROR] database connection failed"
  exit 0
fi

# Check if pane list is requested
if [ "$1" == "pane" ] && [ "$2" == "list" ]; then
  echo '{"id":"cli:pane:list","result":{"panes":[{"agent_status":"unknown","cwd":"/Users/oishik","focused":false,"foreground_cwd":"/Users/oishik","pane_id":"w2:p1","revision":0,"tab_id":"w2:t1","terminal_id":"term_1","workspace_id":"w2"},{"agent_status":"unknown","cwd":"/Users/oishik/apps/herdr-prompter","focused":true,"foreground_cwd":"/Users/oishik/apps/herdr-prompter","label":"Prompter UI","pane_id":"w2:p2","revision":0,"tab_id":"w2:t1","terminal_id":"term_2","workspace_id":"w2"},{"agent_status":"unknown","cwd":"/Users/oishik/apps/herdr-prompter","focused":false,"foreground_cwd":"/Users/oishik/apps/herdr-prompter","label":"Other Pane","pane_id":"w2:p3","revision":0,"tab_id":"w2:t1","terminal_id":"term_3","workspace_id":"w2"}]},"type":"pane_list"}'
  exit 0
fi

echo "[MOCK HERDR] Executed: $*"
EOF
chmod +x "$MOCK_BIN_DIR/herdr"

# Export environments
export HERDR_BIN_PATH="$MOCK_BIN_DIR/herdr"
export HERDR_PLUGIN_CONFIG_DIR="$MOCK_CONFIG_DIR"
export PATH="$MOCK_BIN_DIR:$PATH"

# Setup common context JSON
# shellcheck disable=SC2089
HERDR_PLUGIN_CONTEXT_JSON="{\"focused_pane_id\": \"w2:p2\", \"workspace_cwd\": \"$(pwd)\", \"selected_text\": \"fn test() {}\"}"
# shellcheck disable=SC2090
export HERDR_PLUGIN_CONTEXT_JSON

# Create mock git state in a dedicated temp subfolder to avoid touching repository .git
MOCK_GIT_DIR="$TEST_DIR/mock_git_repo"
mkdir -p "$MOCK_GIT_DIR"
cd "$MOCK_GIT_DIR" || exit 1

git init &>/dev/null
echo "unstaged line" > dummy_git_file.txt
echo "staged line" > dummy_staged_file.txt
git add dummy_staged_file.txt &>/dev/null

echo "=== Test 1: Git placeholders ==="
export TEST_STAGE="git"
bash "$PROMPTER_SCRIPT"

echo "=== Test 2: Staged Git changes ==="
export TEST_STAGE="staged_git"
bash "$PROMPTER_SCRIPT"

echo "=== Test 3: Smart Error logs capture ==="
export TEST_STAGE="error_logs"
bash "$PROMPTER_SCRIPT"

echo "=== Test 4: Custom variable input ==="
export TEST_STAGE="customvar"
# env is read manually, service is picked via mock fzf (outputs "frontend")
echo "production" | bash "$PROMPTER_SCRIPT"

echo "=== Test 5: Multi-Pane Broadcast ==="
export TEST_STAGE="broadcast"
# Custom input placeholder resolved manually
echo "systemctl restart db" | bash "$PROMPTER_SCRIPT"

echo "=== Test 6: Prompt History recall ==="
# Verify that the history file exists
if [ -f "$MOCK_CONFIG_DIR/prompter_history.txt" ]; then
  echo "Verified: prompter_history.txt exists and is not empty."
  cat "$MOCK_CONFIG_DIR/prompter_history.txt"
fi
export TEST_STAGE="use_history"
bash "$PROMPTER_SCRIPT"

echo "=== Test 7: Preview mode (--preview-only) ==="
bash "$PROMPTER_SCRIPT" --preview-only "Explain Error Logs" "$HERDR_PLUGIN_CONTEXT_JSON"

# Cleanup mock environment
cd "$TEST_DIR" || exit 1
rm -rf "$MOCK_CONFIG_DIR" "$MOCK_BIN_DIR" "$MOCK_GIT_DIR"
echo "=== All tests completed ==="

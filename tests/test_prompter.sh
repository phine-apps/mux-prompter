#!/usr/bin/env bash
# Mux Prompter - Unit / Integration Tests
# SPDX-License-Identifier: MIT

# Test script paths
TEST_DIR="$(cd "$(dirname "$0")" && pwd)"
PROMPTER_SCRIPT="$(cd "$TEST_DIR/.." && pwd)/prompter.sh"
PROMPTER_TMUX="$(cd "$TEST_DIR/.." && pwd)/prompter.tmux"
cd "$TEST_DIR" || exit 1

# Ensure Git commands in tests are isolated and non-interactive
export GIT_CONFIG_NOSYSTEM=1
export GIT_CONFIG_GLOBAL=/dev/null
export PAGER=cat
unset GIT_DIR
unset GIT_WORK_TREE

# Config directory setup
MOCK_CONFIG_DIR="$TEST_DIR/mock_config"
MOCK_LOG_DIR="$TEST_DIR/mock_log"
mkdir -p "$MOCK_CONFIG_DIR"
mkdir -p "$MOCK_LOG_DIR"

# Set PATH to use static mocks
export PATH="$TEST_DIR/mocks:$PATH"
export MOCK_LOG_DIR

# Common assertions
assert_contains() {
  local output="$1"
  local expected="$2"
  local name="$3"
  if [[ "$output" != *"$expected"* ]]; then
    echo "FAIL: $name - Output did not contain '$expected'" >&2
    echo "Output: $output" >&2
    exit 1
  else
    echo "PASS: $name"
  fi
}

assert_not_contains() {
  local output="$1"
  local expected="$2"
  local name="$3"
  if [[ "$output" == *"$expected"* ]]; then
    echo "FAIL: $name - Output contained '$expected'" >&2
    echo "Output: $output" >&2
    exit 1
  else
    echo "PASS: $name"
  fi
}

clear_logs() {
  rm -f "$MOCK_LOG_DIR"/*.log
}

# Template definitions
write_templates() {
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
Explain Terminal Error|Help me debug this error:\n\n{{error}}
Extract Lines|Extracting lines from file:\n\n{{file:lines=2-4}}
File Path Test|Path is {{file_path}}
Hang Prevention Test|This has raw {{input}} inside selected: {{selected}}
Refactor Selected Code|Please refactor this code:\n\n{{selected}}
EOF
}

write_templates

# Export environments
export HERDR_BIN_PATH="herdr"
export TMUX_BIN_PATH="tmux"
export HERDR_PLUGIN_CONFIG_DIR="$MOCK_CONFIG_DIR"

# Setup common context JSON for Herdr
HERDR_PLUGIN_CONTEXT_JSON="{\"focused_pane_id\": \"w2:p2\", \"workspace_cwd\": \"$(pwd)\", \"selected_text\": \"fn test() {}\"}"
export HERDR_PLUGIN_CONTEXT_JSON

# Create mock git state in a dedicated temp subfolder to avoid touching repository .git
MOCK_GIT_DIR="$TEST_DIR/mock_git_repo"
mkdir -p "$MOCK_GIT_DIR"
cd "$MOCK_GIT_DIR" || exit 1

git init
git config user.name "Test"
git config user.email "test@example.com"
echo "unstaged line 1" > dummy_git_file.txt
echo "unstaged line 2" >> dummy_git_file.txt
git add dummy_git_file.txt
git commit -m "initial commit" &>/dev/null
echo "staged line" > dummy_staged_file.txt
git add dummy_staged_file.txt

# Re-export context JSON with updated CWD to mock git repo to avoid running diff on active repository
HERDR_PLUGIN_CONTEXT_JSON="{\"focused_pane_id\": \"w2:p2\", \"workspace_cwd\": \"$MOCK_GIT_DIR\", \"selected_text\": \"fn test() {}\"}"
export HERDR_PLUGIN_CONTEXT_JSON

# Create a large dummy file for preview truncation tests
echo -e "line1\nline2\nline3\nline4\nline5\nline6\nline7\nline8\nline9\nline10\nline11\nline12\nline13\nline14\nline15\nline16\nline17\nline18\nline19\nline20\nline21\nline22\nline23\nline24\nline25\nline26\nline27\nline28\nline29\nline30\nline31" > dummy_test_file.txt


# --- TESTS START ---

# Test T-01: Auto-generation of templates.txt
echo "=== Test T-01: Auto-generation of templates.txt ==="
TEMP_CONFIG_DIR="$TEST_DIR/temp_config_t01"
rm -rf "$TEMP_CONFIG_DIR"
export HERDR_PLUGIN_CONFIG_DIR="$TEMP_CONFIG_DIR"
export TEST_STAGE="cancel"
bash "$PROMPTER_SCRIPT" &>/dev/null
if [ -f "$TEMP_CONFIG_DIR/templates.txt" ]; then
  echo "PASS: templates.txt auto-generated"
else
  echo "FAIL: templates.txt not generated"
  exit 1
fi
rm -rf "$TEMP_CONFIG_DIR"
export HERDR_PLUGIN_CONFIG_DIR="$MOCK_CONFIG_DIR"


# Test T-03: Immediate reflection of template edits
echo "=== Test T-03: Immediate reflection of template edits ==="
echo "Dynamic Template|dynamic content" >> "$MOCK_CONFIG_DIR/templates.txt"
output=$(bash "$PROMPTER_SCRIPT" --list-templates)
assert_contains "$output" "Dynamic Template" "T-03 reflection"
write_templates


# Test H-01a: selected priority (Herdr)
echo "=== Test H-01a: selected priority (Herdr) ==="
export TEST_STAGE="selected_test"
export MUX_BACKEND="herdr"
output=$(bash "$PROMPTER_SCRIPT")
assert_contains "$output" "fn test() {}" "H-01a Herdr selection"
assert_not_contains "$output" "clip_selected" "H-01a clipboard ignored"


# Test H-01b: selected priority (tmux)
echo "=== Test H-01b: selected priority (tmux) ==="
export TEST_STAGE="selected_test"
export MUX_BACKEND="tmux"
export TMUX_PANE="%0"
output=$(bash "$PROMPTER_SCRIPT")
assert_contains "$output" "clip_selected" "H-01b tmux selected (clipboard)"
assert_not_contains "$output" "mocked_tmux_buffer" "H-01b tmux selected (buffer ignored)"


# Test H-02: git diff preview 25 lines limit
echo "=== Test H-02: git diff preview 25 lines limit ==="
export MUX_BACKEND="herdr"
(for i in {1..30}; do echo "change $i" >> dummy_git_file.txt; done)
output=$(bash "$PROMPTER_SCRIPT" --preview-only "Review Git Changes" "$HERDR_PLUGIN_CONTEXT_JSON")
assert_contains "$output" "change 5" "H-02 git diff output present"
assert_contains "$output" "truncated for preview" "H-02 truncated message present"
echo -e "unstaged line 1\nunstaged line 2" > dummy_git_file.txt


# Test H-03 & H-04: git status & git branch
echo "=== Test H-03 & H-04: git status & git branch ==="
echo "Git Meta Test|Branch: {{git_branch}} Status: {{git_status}}" >> "$MOCK_CONFIG_DIR/templates.txt"
output=$(bash "$PROMPTER_SCRIPT" --preview-only "Git Meta Test" "$HERDR_PLUGIN_CONTEXT_JSON")
assert_contains "$output" "dummy_test_file.txt" "H-03 git status resolved"
assert_not_contains "$output" "no-branch" "H-04 git branch resolved"
write_templates


# Test H-05: pane logs capture
echo "=== Test H-05: pane logs capture ==="
export TEST_STAGE="logs"
export MUX_BACKEND="herdr"
output=$(bash "$PROMPTER_SCRIPT")
assert_contains "$output" "database connection failed" "H-05 pane logs content resolved"


# Test H-06: last command capture
echo "=== Test H-06: last command capture ==="
export TEST_STAGE="lastcmd"
output=$(bash "$PROMPTER_SCRIPT")
assert_contains "$output" "Last command: npm run dev" "H-06 last command parsed from logs"


# Test H-08: file content insertion
echo "=== Test H-08: file content insertion ==="
export TEST_STAGE="file"
output=$(bash "$PROMPTER_SCRIPT")
assert_contains "$output" "line25" "H-08 file content resolved"


# Test H-09: error automatic detection
echo "=== Test H-09: error automatic detection ==="
export TEST_STAGE="error"
output=$(bash "$PROMPTER_SCRIPT")
assert_contains "$output" "[ERROR] database connection failed" "H-09 error line captured"


# Test H-13: file:lines range extraction
echo "=== Test H-13: file:lines range extraction ==="
export TEST_STAGE="file_lines"
output=$(bash "$PROMPTER_SCRIPT")
assert_contains "$output" "line2" "H-13 start line"
assert_contains "$output" "line4" "H-13 end line"
assert_not_contains "$output" "line1" "H-13 preceding line skipped"
assert_not_contains "$output" "line5" "H-13 following line skipped"


# Test H-14: file path insertion
echo "=== Test H-14: file path insertion ==="
export TEST_STAGE="file_path"
output=$(bash "$PROMPTER_SCRIPT")
assert_contains "$output" "dummy_test_file.txt" "H-14 path inserted"
assert_not_contains "$output" "line25" "H-14 content not inserted"


# Test V-01 to V-04: View lists
echo "=== Test V-01 to V-04: View lists (Templates, History, All) ==="
out_templates=$(bash "$PROMPTER_SCRIPT" --list-templates)
assert_contains "$out_templates" "Review Git Changes" "V-01 templates list"
assert_not_contains "$out_templates" "📜" "V-01 history symbols excluded"

echo "Hello World from history" > "$MOCK_CONFIG_DIR/prompter_history.txt"
out_history=$(bash "$PROMPTER_SCRIPT" --list-history)
assert_contains "$out_history" "Hello World from history" "V-02 history list"

out_all=$(bash "$PROMPTER_SCRIPT" --list-all)
assert_contains "$out_all" "Review Git Changes" "V-04 templates inside all"
assert_contains "$out_all" "Hello World from history" "V-04 history inside all"


# Test A-01: missing dependencies (jq / fzf)
echo "=== Test A-01: missing dependencies (jq / fzf) ==="
command() {
  if [[ "$1" == "-v" ]] && { [[ "$2" == "jq" ]] || [[ "$2" == "fzf" ]]; }; then
    return 1
  fi
  builtin command "$@"
}
export -f command

output=$(bash "$PROMPTER_SCRIPT" 2>&1 </dev/null)
if [[ $? -ne 0 ]] || [[ "$output" == *"is required"* ]]; then
  echo "PASS: missing dependencies handled safely"
else
  echo "FAIL: missing dependencies check bypassed"
  unset -f command
  exit 1
fi
unset -f command


# Test A-02: Non-Git directory fallback
echo "=== Test A-02: Non-Git directory fallback ==="
NON_GIT_DIR="$TEST_DIR/non_git_dir"
mkdir -p "$NON_GIT_DIR"
cd "$NON_GIT_DIR" || exit 1
NON_GIT_CONTEXT="{\"focused_pane_id\": \"w2:p2\", \"workspace_cwd\": \"$NON_GIT_DIR\"}"
export GIT_CEILING_DIRECTORIES="$(cd "$TEST_DIR/.." && pwd)"
output=$(bash "$PROMPTER_SCRIPT" --preview-only "Review Git Changes" "$NON_GIT_CONTEXT")
assert_contains "$output" "No git changes" "A-02 git diff fallback"
unset GIT_CEILING_DIRECTORIES
cd "$MOCK_GIT_DIR" || exit 1
rm -rf "$NON_GIT_DIR"


# Test A-03: fzf cancelled safely
echo "=== Test A-03: fzf cancelled safely ==="
export TEST_STAGE="cancel"
bash "$PROMPTER_SCRIPT"
if [ $? -eq 0 ]; then
  echo "PASS: fzf cancel exited status 0"
else
  echo "FAIL: fzf cancel exited status $?"
  exit 1
fi


# Test A-04: Re-entry / loop prevention
echo "=== Test A-04: Re-entry / loop prevention ==="
export TEST_STAGE="hang_test"
HANG_CONTEXT="{\"focused_pane_id\": \"w2:p2\", \"workspace_cwd\": \"$MOCK_GIT_DIR\", \"selected_text\": \"raw {{input}} text\"}"
output=$(bash "$PROMPTER_SCRIPT" --preview-only "Hang Prevention Test" "$HANG_CONTEXT")
assert_contains "$output" "raw {{input}} text" "A-04 raw placeholder not evaluated recursively"


# Test A-05: tmux older version compatibility (TPM entrypoint)
echo "=== Test A-05: tmux older version compatibility ==="
export TMUX_POPUP_FAIL="0"
clear_logs
output=$(bash "$PROMPTER_TMUX" 2>&1)
assert_contains "$(cat "$MOCK_LOG_DIR/tmux_calls.log")" "bind-key P display-popup" "A-05 tmux popup bind"

export TMUX_POPUP_FAIL="1"
clear_logs
output=$(bash "$PROMPTER_TMUX" 2>&1)
assert_contains "$(cat "$MOCK_LOG_DIR/tmux_calls.log")" "bind-key P split-window" "A-05 tmux split-window bind"


# --- NEW SPYING & CALL HISTORY TESTS ---

# Test X-01: Standard Text Injection (Spying)
echo "=== Test X-01: Standard Text Injection (Spying) ==="
export TEST_STAGE="logs"
export MUX_BACKEND="herdr"
clear_logs
bash "$PROMPTER_SCRIPT" &>/dev/null
assert_contains "$(cat "$MOCK_LOG_DIR/herdr_calls.log")" "pane send-text w2:p2 Here are the target pane logs:" "X-01 herdr send-text called"


# Test X-03: Multi-Pane Broadcast (Spying)
echo "=== Test X-03: Multi-Pane Broadcast (Spying) ==="
export TEST_STAGE="broadcast"
export MUX_BACKEND="herdr"
clear_logs
echo "systemctl restart db" | bash "$PROMPTER_SCRIPT" &>/dev/null
assert_contains "$(cat "$MOCK_LOG_DIR/herdr_calls.log")" "pane send-text w2:p1" "X-03 broadcast to w2:p1"
assert_contains "$(cat "$MOCK_LOG_DIR/herdr_calls.log")" "pane send-text w2:p3" "X-03 broadcast to w2:p3"


# --- NEW ENVIRONMENT DETECTION TESTS (I-06 to I-08) ---

# Test I-06: Auto-detection (tmux)
echo "=== Test I-06: Auto-detection (tmux) ==="
export TMUX="/tmp/tmux-1000/default,1234,0"
export TMUX_PANE="%0"
unset HERDR_PLUGIN_CONTEXT_JSON
export MUX_BACKEND="auto"
export TEST_STAGE="logs"
clear_logs
bash "$PROMPTER_SCRIPT" &>/dev/null
assert_contains "$(cat "$MOCK_LOG_DIR/tmux_calls.log")" "capture-pane" "I-06 auto-detect tmux"
unset TMUX
unset TMUX_PANE


# Test I-07: Auto-detection (Herdr)
echo "=== Test I-07: Auto-detection (Herdr) ==="
HERDR_PLUGIN_CONTEXT_JSON="{\"focused_pane_id\": \"w2:p2\", \"workspace_cwd\": \"$MOCK_GIT_DIR\", \"selected_text\": \"fn test() {}\"}"
export HERDR_PLUGIN_CONTEXT_JSON
export MUX_BACKEND="auto"
export TEST_STAGE="logs"
clear_logs
bash "$PROMPTER_SCRIPT" &>/dev/null
assert_contains "$(cat "$MOCK_LOG_DIR/herdr_calls.log")" "pane read w2:p2" "I-07 auto-detect herdr"
assert_not_contains "$(cat "$MOCK_LOG_DIR/tmux_calls.log" 2>/dev/null || true)" "capture-pane" "I-07 tmux not called"


# Test I-08: Explicit Backend Override
echo "=== Test I-08: Explicit Backend Override ==="
export TMUX="/tmp/tmux-1000/default,1234,0"
export TMUX_PANE="%0"
export MUX_BACKEND="herdr"
export TEST_STAGE="logs"
clear_logs
bash "$PROMPTER_SCRIPT" &>/dev/null
assert_contains "$(cat "$MOCK_LOG_DIR/herdr_calls.log")" "pane read w2:p2" "I-08 override to herdr"
assert_not_contains "$(cat "$MOCK_LOG_DIR/tmux_calls.log" 2>/dev/null || true)" "capture-pane" "I-08 override tmux skipped"
unset TMUX
unset TMUX_PANE


# Cleanup mock environment
cd "$TEST_DIR" || exit 1
rm -rf "$MOCK_CONFIG_DIR" "$MOCK_LOG_DIR" "$MOCK_GIT_DIR"
echo "=== All tests completed successfully ==="

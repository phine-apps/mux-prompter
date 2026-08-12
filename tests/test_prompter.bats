#!/usr/bin/env bats
# Mux Prompter - Unit / Integration Tests (Bats version)
# SPDX-License-Identifier: MIT

# Each test gets a completely isolated, unique temporary environment
setup() {
  TEST_TEMP_DIR="$(mktemp -d -t prompter-tests-XXXXXX)"
  export MOCK_CONFIG_DIR="$TEST_TEMP_DIR/mock_config"
  export MOCK_LOG_DIR="$TEST_TEMP_DIR/mock_log"
  export MOCK_GIT_DIR="$TEST_TEMP_DIR/mock_git_repo"
  mkdir -p "$MOCK_CONFIG_DIR" "$MOCK_LOG_DIR" "$MOCK_GIT_DIR"

  # Path configuration (prioritizing mock executables)
  export PATH="$BATS_TEST_DIRNAME/mocks:$PATH"
  export PROMPTER_SCRIPT="$BATS_TEST_DIRNAME/../prompter.sh"
  export PROMPTER_TMUX="$BATS_TEST_DIRNAME/../prompter.tmux"

  # Ensure Git commands in tests are isolated and non-interactive
  export GIT_CONFIG_NOSYSTEM=1
  export GIT_CONFIG_GLOBAL=/dev/null
  export PAGER=cat
  unset GIT_DIR
  unset GIT_WORK_TREE

  # Mock environment variables
  export MOCK_LOG_DIR
  export HERDR_BIN_PATH="herdr"
  export TMUX_BIN_PATH="tmux"
  export HERDR_PLUGIN_CONFIG_DIR="$MOCK_CONFIG_DIR"

  # Write initial templates to the mock config directory
  write_templates

  # Initialize mock Git repository inside mock git subfolder
  cd "$MOCK_GIT_DIR" || exit 1
  git init -q
  git config user.name "Test"
  git config user.email "test@example.com"
  echo "unstaged line 1" > dummy_git_file.txt
  echo "unstaged line 2" >> dummy_git_file.txt
  git add dummy_git_file.txt
  git commit -m "initial commit" -q &>/dev/null
  echo "staged line" > dummy_staged_file.txt
  git add dummy_staged_file.txt

  # Setup standard plugin contexts
  HERDR_PLUGIN_CONTEXT_JSON="{\"focused_pane_id\": \"w2:p2\", \"workspace_cwd\": \"$MOCK_GIT_DIR\", \"selected_text\": \"fn test() {}\"}"
  export HERDR_PLUGIN_CONTEXT_JSON

  # Create large dummy file for preview truncation tests
  echo -e "line1\nline2\nline3\nline4\nline5\nline6\nline7\nline8\nline9\nline10\nline11\nline12\nline13\nline14\nline15\nline16\nline17\nline18\nline19\nline20\nline21\nline22\nline23\nline24\nline25\nline26\nline27\nline28\nline29\nline30\nline31" > dummy_test_file.txt
}

teardown() {
  # Change back to bats test directory before cleaning up
  cd "$BATS_TEST_DIRNAME"
  rm -rf "$TEST_TEMP_DIR"
}

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

# --- TESTS START ---

@test "T-01: Auto-generation of templates.txt" {
  TEMP_CONFIG_DIR="$TEST_TEMP_DIR/temp_config_t01"
  export HERDR_PLUGIN_CONFIG_DIR="$TEMP_CONFIG_DIR"
  export TEST_STAGE="cancel"
  run bash "$PROMPTER_SCRIPT"
  [ -f "$TEMP_CONFIG_DIR/templates.txt" ]
}

@test "T-03: Immediate reflection of template edits" {
  echo "Dynamic Template|dynamic content" >> "$MOCK_CONFIG_DIR/templates.txt"
  run bash "$PROMPTER_SCRIPT" --list-templates
  [ "$status" -eq 0 ]
  [[ "$output" == *"Dynamic Template"* ]]
}

@test "H-01a: selected priority (Herdr)" {
  export TEST_STAGE="selected_test"
  export MUX_BACKEND="herdr"
  run bash "$PROMPTER_SCRIPT"
  [ "$status" -eq 0 ]
  [[ "$output" == *"fn test() {}"* ]]
  [[ "$output" != *"clip_selected"* ]]
}

@test "H-01b: selected priority (tmux)" {
  export TEST_STAGE="selected_test"
  export MUX_BACKEND="tmux"
  export TMUX_PANE="%0"
  run bash "$PROMPTER_SCRIPT"
  [ "$status" -eq 0 ]
  [[ "$output" == *"clip_selected"* ]]
  [[ "$output" != *"mocked_tmux_buffer"* ]]
}

@test "H-02: git diff preview 25 lines limit" {
  export MUX_BACKEND="herdr"
  # Add 30 change lines to trigger truncation
  for i in {1..30}; do
    echo "change $i" >> dummy_git_file.txt
  done
  run bash "$PROMPTER_SCRIPT" --preview-only "Review Git Changes" "$HERDR_PLUGIN_CONTEXT_JSON"
  [ "$status" -eq 0 ]
  [[ "$output" == *"change 5"* ]]
  [[ "$output" == *"truncated for preview"* ]]
}

@test "H-03 & H-04: git status & git branch" {
  echo "Git Meta Test|Branch: {{git_branch}} Status: {{git_status}}" >> "$MOCK_CONFIG_DIR/templates.txt"
  run bash "$PROMPTER_SCRIPT" --preview-only "Git Meta Test" "$HERDR_PLUGIN_CONTEXT_JSON"
  [ "$status" -eq 0 ]
  [[ "$output" == *"dummy_test_file.txt"* ]]
  [[ "$output" != *"no-branch"* ]]
}

@test "H-05: pane logs capture" {
  export TEST_STAGE="logs"
  export MUX_BACKEND="herdr"
  run bash "$PROMPTER_SCRIPT"
  [ "$status" -eq 0 ]
  [[ "$output" == *"database connection failed"* ]]
}

@test "H-06: last command capture" {
  export TEST_STAGE="lastcmd"
  run bash "$PROMPTER_SCRIPT"
  [ "$status" -eq 0 ]
  [[ "$output" == *"Last command: npm run dev"* ]]
}

@test "H-08: file content insertion" {
  export TEST_STAGE="file"
  run bash "$PROMPTER_SCRIPT"
  [ "$status" -eq 0 ]
  [[ "$output" == *"line25"* ]]
}

@test "H-09: error automatic detection" {
  export TEST_STAGE="error"
  run bash "$PROMPTER_SCRIPT"
  [ "$status" -eq 0 ]
  [[ "$output" == *"[ERROR] database connection failed"* ]]
}

@test "H-13: file:lines range extraction" {
  export TEST_STAGE="file_lines"
  run bash "$PROMPTER_SCRIPT"
  [ "$status" -eq 0 ]
  [[ "$output" == *"line2"* ]]
  [[ "$output" == *"line4"* ]]
  [[ "$output" != *"line1"* ]]
  [[ "$output" != *"line5"* ]]
}

@test "H-14: file path insertion" {
  export TEST_STAGE="file_path"
  run bash "$PROMPTER_SCRIPT"
  [ "$status" -eq 0 ]
  [[ "$output" == *"dummy_test_file.txt"* ]]
  [[ "$output" != *"line25"* ]]
}

@test "V-01 to V-04: View lists (Templates, History, All)" {
  run bash "$PROMPTER_SCRIPT" --list-templates
  [ "$status" -eq 0 ]
  [[ "$output" == *"Review Git Changes"* ]]
  [[ "$output" != *"📜"* ]]

  echo "Hello World from history" > "$MOCK_CONFIG_DIR/prompter_history.txt"
  run bash "$PROMPTER_SCRIPT" --list-history
  [ "$status" -eq 0 ]
  [[ "$output" == *"Hello World from history"* ]]

  run bash "$PROMPTER_SCRIPT" --list-all
  [ "$status" -eq 0 ]
  [[ "$output" == *"Review Git Changes"* ]]
  [[ "$output" == *"Hello World from history"* ]]
}

@test "A-01: missing dependencies (jq / fzf)" {
  # Mock the `command` shell builtin/function to pretend jq/fzf are missing
  command() {
    if [[ "$1" == "-v" ]] && { [[ "$2" == "jq" ]] || [[ "$2" == "fzf" ]]; }; then
      return 1
    fi
    builtin command "$@"
  }
  export -f command

  run bash "$PROMPTER_SCRIPT"
  [ "$status" -ne 0 ] || [[ "$output" == *"is required"* ]]
}

@test "A-02: Non-Git directory fallback" {
  NON_GIT_DIR="$TEST_TEMP_DIR/non_git_dir"
  mkdir -p "$NON_GIT_DIR"
  cd "$NON_GIT_DIR" || exit 1
  NON_GIT_CONTEXT="{\"focused_pane_id\": \"w2:p2\", \"workspace_cwd\": \"$NON_GIT_DIR\"}"
  export GIT_CEILING_DIRECTORIES="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"
  
  run bash "$PROMPTER_SCRIPT" --preview-only "Review Git Changes" "$NON_GIT_CONTEXT"
  [ "$status" -eq 0 ]
  [[ "$output" == *"No git changes"* ]]
}

@test "A-03: fzf cancelled safely" {
  export TEST_STAGE="cancel"
  run bash "$PROMPTER_SCRIPT"
  [ "$status" -eq 0 ]
}

@test "A-04: Re-entry / loop prevention" {
  export TEST_STAGE="hang_test"
  HANG_CONTEXT="{\"focused_pane_id\": \"w2:p2\", \"workspace_cwd\": \"$MOCK_GIT_DIR\", \"selected_text\": \"raw {{input}} text\"}"
  run bash "$PROMPTER_SCRIPT" --preview-only "Hang Prevention Test" "$HANG_CONTEXT"
  [ "$status" -eq 0 ]
  [[ "$output" == *"raw {{input}} text"* ]]
}

@test "A-05: tmux older version compatibility (TPM entrypoint)" {
  export TMUX_POPUP_FAIL="0"
  rm -f "$MOCK_LOG_DIR"/*.log
  run bash "$PROMPTER_TMUX"
  [ "$status" -eq 0 ]
  [[ "$(cat "$MOCK_LOG_DIR/tmux_calls.log")" == *"bind-key P display-popup"* ]]

  export TMUX_POPUP_FAIL="1"
  rm -f "$MOCK_LOG_DIR"/*.log
  run bash "$PROMPTER_TMUX"
  [ "$status" -eq 0 ]
  [[ "$(cat "$MOCK_LOG_DIR/tmux_calls.log")" == *"bind-key P split-window"* ]]
}

@test "X-01: Standard Text Injection (Spying)" {
  export TEST_STAGE="logs"
  export MUX_BACKEND="herdr"
  rm -f "$MOCK_LOG_DIR"/*.log
  run bash "$PROMPTER_SCRIPT"
  [ "$status" -eq 0 ]
  [[ "$(cat "$MOCK_LOG_DIR/herdr_calls.log")" == *"pane send-text w2:p2 Here are the target pane logs:"* ]]
}

@test "X-03: Multi-Pane Broadcast (Spying)" {
  export TEST_STAGE="broadcast"
  export MUX_BACKEND="herdr"
  rm -f "$MOCK_LOG_DIR"/*.log
  run bash -c "echo 'systemctl restart db' | bash '$PROMPTER_SCRIPT'"
  [ "$status" -eq 0 ]
  [[ "$(cat "$MOCK_LOG_DIR/herdr_calls.log")" == *"pane send-text w2:p1"* ]]
  [[ "$(cat "$MOCK_LOG_DIR/herdr_calls.log")" == *"pane send-text w2:p3"* ]]
}

@test "I-06: Auto-detection (tmux)" {
  export TMUX="/tmp/tmux-1000/default,1234,0"
  export TMUX_PANE="%0"
  unset HERDR_PLUGIN_CONTEXT_JSON
  export MUX_BACKEND="auto"
  export TEST_STAGE="logs"
  rm -f "$MOCK_LOG_DIR"/*.log
  run bash "$PROMPTER_SCRIPT"
  [ "$status" -eq 0 ]
  [[ "$(cat "$MOCK_LOG_DIR/tmux_calls.log")" == *"capture-pane"* ]]
}

@test "I-07: Auto-detection (Herdr)" {
  HERDR_PLUGIN_CONTEXT_JSON="{\"focused_pane_id\": \"w2:p2\", \"workspace_cwd\": \"$MOCK_GIT_DIR\", \"selected_text\": \"fn test() {}\"}"
  export HERDR_PLUGIN_CONTEXT_JSON
  export MUX_BACKEND="auto"
  export TEST_STAGE="logs"
  rm -f "$MOCK_LOG_DIR"/*.log
  run bash "$PROMPTER_SCRIPT"
  [ "$status" -eq 0 ]
  [[ "$(cat "$MOCK_LOG_DIR/herdr_calls.log")" == *"pane read w2:p2"* ]]
  [ ! -f "$MOCK_LOG_DIR/tmux_calls.log" ] || [[ "$(cat "$MOCK_LOG_DIR/tmux_calls.log")" != *"capture-pane"* ]]
}

@test "I-08: Explicit Backend Override" {
  export TMUX="/tmp/tmux-1000/default,1234,0"
  export TMUX_PANE="%0"
  export MUX_BACKEND="herdr"
  export TEST_STAGE="logs"
  rm -f "$MOCK_LOG_DIR"/*.log
  run bash "$PROMPTER_SCRIPT"
  [ "$status" -eq 0 ]
  [[ "$(cat "$MOCK_LOG_DIR/herdr_calls.log")" == *"pane read w2:p2"* ]]
  [ ! -f "$MOCK_LOG_DIR/tmux_calls.log" ] || [[ "$(cat "$MOCK_LOG_DIR/tmux_calls.log")" != *"capture-pane"* ]]
}

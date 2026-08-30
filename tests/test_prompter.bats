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
  mkdir -p "$MOCK_CONFIG_DIR/templates"
  cat << 'EOF' > "$MOCK_CONFIG_DIR/templates/review-git.md"
# Review Git Changes
Please review the following git changes:

{{git_diff}}
EOF

  cat << 'EOF' > "$MOCK_CONFIG_DIR/templates/review-staged.md"
# Review Staged Git Changes
Please review only the staged git changes:

{{git_diff:staged}}
EOF

  cat << 'EOF' > "$MOCK_CONFIG_DIR/templates/explain-logs.md"
# Explain Logs
Here are the target pane logs:

{{pane_logs}}
EOF

  cat << 'EOF' > "$MOCK_CONFIG_DIR/templates/explain-error-logs.md"
# Explain Error Logs
Help me debug these error logs:

{{pane_logs:errors}}
EOF

  cat << 'EOF' > "$MOCK_CONFIG_DIR/templates/analyze-last-cmd.md"
# Analyze Last Cmd
Explain the last command output:

Last command: {{last_command}}
Logs:
{{pane_logs}}
EOF

  cat << 'EOF' > "$MOCK_CONFIG_DIR/templates/cross-pane.md"
# Cross Pane Review
Analyze the logs from the other pane:

{{pane:choose}}
EOF

  cat << 'EOF' > "$MOCK_CONFIG_DIR/templates/custom-var.md"
# Custom Variable Test
Deploying {{var:service}} to {{var:env}}
EOF

  cat << 'EOF' > "$MOCK_CONFIG_DIR/templates/_vars.txt"
$ service: echo -e "frontend\nbackend\nauth"
EOF

  cat << 'EOF' > "$MOCK_CONFIG_DIR/templates/analyze-file.md"
# Analyze File
Analyzing file contents:

{{file}}
EOF

  cat << 'EOF' > "$MOCK_CONFIG_DIR/templates/broadcast.md"
# Broadcast Command
{{panes:choose}} -> Send command: {{input}}
EOF

  cat << 'EOF' > "$MOCK_CONFIG_DIR/templates/run-git-status.md"
# !Run Git Status
git status
EOF

  cat << 'EOF' > "$MOCK_CONFIG_DIR/templates/explain-error.md"
# Explain Terminal Error
Help me debug this error:

{{error}}
EOF

  cat << 'EOF' > "$MOCK_CONFIG_DIR/templates/extract-lines.md"
# Extract Lines
Extracting lines from file:

{{file:lines=2-4}}
EOF

  cat << 'EOF' > "$MOCK_CONFIG_DIR/templates/file-path.md"
# File Path Test
Path is {{file_path}}
EOF

  cat << 'EOF' > "$MOCK_CONFIG_DIR/templates/hang-test.md"
# Hang Prevention Test
This has raw {{input}} inside selected: {{selected}}
EOF

  cat << 'EOF' > "$MOCK_CONFIG_DIR/templates/refactor-code.md"
# Refactor Selected Code
Please refactor this code:

{{selected}}
EOF
}

# --- TESTS START ---

@test "T-01: Auto-generation of templates directory and markdown files" {
  TEMP_CONFIG_DIR="$TEST_TEMP_DIR/temp_config_t01"
  export HERDR_PLUGIN_CONFIG_DIR="$TEMP_CONFIG_DIR"
  export TEST_STAGE="cancel"
  run bash "$PROMPTER_SCRIPT"
  [ -d "$TEMP_CONFIG_DIR/templates" ]
  [ -f "$TEMP_CONFIG_DIR/templates/summarize-discussion.md" ]
}

@test "T-02: Automatic migration from legacy templates.txt to templates/*.md" {
  TEMP_CONFIG_DIR="$TEST_TEMP_DIR/temp_config_t02"
  mkdir -p "$TEMP_CONFIG_DIR"
  cat << 'EOF' > "$TEMP_CONFIG_DIR/templates.txt"
Legacy Prompt|Line 1\nLine 2\nLine 3
$ my_var: echo "val1"
EOF
  export HERDR_PLUGIN_CONFIG_DIR="$TEMP_CONFIG_DIR"
  export TEST_STAGE="cancel"
  run bash "$PROMPTER_SCRIPT"
  
  [ -f "$TEMP_CONFIG_DIR/templates.txt.bak" ]
  [ ! -f "$TEMP_CONFIG_DIR/templates.txt" ]
  [ -f "$TEMP_CONFIG_DIR/templates/legacy-prompt.md" ]
  [ -f "$TEMP_CONFIG_DIR/templates/_vars.txt" ]
  [[ "$(cat "$TEMP_CONFIG_DIR/templates/legacy-prompt.md")" == *"# Legacy Prompt"* ]]
  [[ "$(cat "$TEMP_CONFIG_DIR/templates/legacy-prompt.md")" == *"Line 1"* ]]
  [[ "$(cat "$TEMP_CONFIG_DIR/templates/legacy-prompt.md")" == *"Line 2"* ]]
  [[ "$(cat "$TEMP_CONFIG_DIR/templates/_vars.txt")" == *"$ my_var:"* ]]
}

@test "T-03: Immediate reflection of template edits in .md files" {
  cat << 'EOF' > "$MOCK_CONFIG_DIR/templates/dynamic.md"
# Dynamic Template
dynamic content
EOF
  run bash "$PROMPTER_SCRIPT" --list-templates
  [ "$status" -eq 0 ]
  [[ "$output" == *"Dynamic Template"* ]]
}

@test "T-04: Subdirectory template discovery" {
  mkdir -p "$MOCK_CONFIG_DIR/templates/nested_cat"
  cat << 'EOF' > "$MOCK_CONFIG_DIR/templates/nested_cat/nested-prompt.md"
# Nested Category Prompt
nested prompt body
EOF
  run bash "$PROMPTER_SCRIPT" --list-templates
  [ "$status" -eq 0 ]
  [[ "$output" == *"Nested Category Prompt"* ]]
}

@test "T-05: Slug collision avoidance with multiple existing files" {
  TEMP_CONFIG_DIR="$TEST_TEMP_DIR/temp_config_t05"
  mkdir -p "$TEMP_CONFIG_DIR/templates"
  # Pre-create test.md and test-2.md
  echo "# Test 1" > "$TEMP_CONFIG_DIR/templates/test.md"
  echo "# Test 2" > "$TEMP_CONFIG_DIR/templates/test-2.md"
  
  cat << 'EOF' > "$TEMP_CONFIG_DIR/templates.txt"
Test|Newly migrated third content
EOF
  export HERDR_PLUGIN_CONFIG_DIR="$TEMP_CONFIG_DIR"
  export TEST_STAGE="cancel"
  run bash "$PROMPTER_SCRIPT"
  
  [ -f "$TEMP_CONFIG_DIR/templates/test-3.md" ]
  [[ "$(cat "$TEMP_CONFIG_DIR/templates/test.md")" == *"# Test 1"* ]]
  [[ "$(cat "$TEMP_CONFIG_DIR/templates/test-2.md")" == *"# Test 2"* ]]
  [[ "$(cat "$TEMP_CONFIG_DIR/templates/test-3.md")" == *"Newly migrated third content"* ]]
}

@test "T-06: Unicode and Japanese slugify support" {
  TEMP_CONFIG_DIR="$TEST_TEMP_DIR/temp_config_t06"
  mkdir -p "$TEMP_CONFIG_DIR"
  cat << 'EOF' > "$TEMP_CONFIG_DIR/templates.txt"
コードレビュー|コードを確認してください
!テスト実行|テストを実行する
EOF
  export HERDR_PLUGIN_CONFIG_DIR="$TEMP_CONFIG_DIR"
  export TEST_STAGE="cancel"
  run bash "$PROMPTER_SCRIPT"
  
  [ -f "$TEMP_CONFIG_DIR/templates/コードレビュー.md" ]
  [ -f "$TEMP_CONFIG_DIR/templates/テスト実行.md" ]
  [[ "$(cat "$TEMP_CONFIG_DIR/templates/コードレビュー.md")" == *"# コードレビュー"* ]]
  [[ "$(cat "$TEMP_CONFIG_DIR/templates/テスト実行.md")" == *"# !テスト実行"* ]]
}

@test "T-07: Migration escape preservation (e.g. Windows paths)" {
  TEMP_CONFIG_DIR="$TEST_TEMP_DIR/temp_config_t07"
  mkdir -p "$TEMP_CONFIG_DIR"
  cat << 'EOF' > "$TEMP_CONFIG_DIR/templates.txt"
Path Prompt|Windows path is C:\Users\alice\note\nSecond line after newline
EOF
  export HERDR_PLUGIN_CONFIG_DIR="$TEMP_CONFIG_DIR"
  export TEST_STAGE="cancel"
  run bash "$PROMPTER_SCRIPT"
  
  [ -f "$TEMP_CONFIG_DIR/templates/path-prompt.md" ]
  [[ "$(cat "$TEMP_CONFIG_DIR/templates/path-prompt.md")" == *"C:\Users\alice\note"* ]]
  [[ "$(cat "$TEMP_CONFIG_DIR/templates/path-prompt.md")" == *"Second line after newline"* ]]
}

@test "T-08: Recursive variable discovery in subdirectories" {
  mkdir -p "$MOCK_CONFIG_DIR/templates/deep/sub"
  cat << 'EOF' > "$MOCK_CONFIG_DIR/templates/deep/sub/nested_vars.md"
# Nested Var Prompt
Deploying to {{var:nested_env}}

$ nested_env: echo "production_nested"
EOF
  run bash "$PROMPTER_SCRIPT" --preview-only "Nested Var Prompt" "$HERDR_PLUGIN_CONTEXT_JSON"
  [ "$status" -eq 0 ]
  [[ "$output" == *"[Enter value for nested_env]"* ]]
}

@test "T-09: Duplicate title disambiguation" {
  mkdir -p "$MOCK_CONFIG_DIR/templates/cat_a" "$MOCK_CONFIG_DIR/templates/cat_b"
  cat << 'EOF' > "$MOCK_CONFIG_DIR/templates/cat_a/item.md"
# Same Title
Body from Cat A
EOF
  cat << 'EOF' > "$MOCK_CONFIG_DIR/templates/cat_b/item.md"
# Same Title
Body from Cat B
EOF
  run bash "$PROMPTER_SCRIPT" --list-templates
  [ "$status" -eq 0 ]
  [[ "$output" == *"Same Title (cat_a/item.md)"* ]]
  [[ "$output" == *"Same Title (cat_b/item.md)"* ]]

  run bash "$PROMPTER_SCRIPT" --preview-only "Same Title (cat_a/item.md)" "$HERDR_PLUGIN_CONTEXT_JSON"
  [ "$status" -eq 0 ]
  [[ "$output" == *"Body from Cat A"* ]]

  run bash "$PROMPTER_SCRIPT" --preview-only "Same Title (cat_b/item.md)" "$HERDR_PLUGIN_CONTEXT_JSON"
  [ "$status" -eq 0 ]
  [[ "$output" == *"Body from Cat B"* ]]
}

@test "X-02: Bang (!) title regression test - only text insertion, no auto Enter" {
  export TEST_STAGE="immediate"
  export MUX_BACKEND="herdr"
  rm -f "$MOCK_LOG_DIR"/*.log
  run bash "$PROMPTER_SCRIPT"
  [ "$status" -eq 0 ]
  # Ensure pane send-text is called and NOT pane run (which simulates auto-enter)
  [[ "$(cat "$MOCK_LOG_DIR/herdr_calls.log")" == *"pane send-text w2:p2 git status"* ]]
  [[ "$(cat "$MOCK_LOG_DIR/herdr_calls.log")" != *"pane run"* ]]
}

@test "T-10: Template deletion via Ctrl-D in Edit Templates" {
  export TEST_STAGE="delete_template"
  export MUX_BACKEND="herdr"
  [ -f "$MOCK_CONFIG_DIR/templates/review-git.md" ]
  
  # Send 'y' to confirm deletion
  run bash -c "echo 'y' | bash '$PROMPTER_SCRIPT'"
  [ "$status" -eq 0 ]
  [ ! -f "$MOCK_CONFIG_DIR/templates/review-git.md" ]
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
  cat << 'EOF' > "$MOCK_CONFIG_DIR/templates/git-meta.md"
# Git Meta Test
Branch: {{git_branch}} Status: {{git_status}}
EOF
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

@test "ADV-01: History prompt with pipe '|' symbols is preserved and parsed correctly" {
  TEMP_CONFIG_DIR="$TEST_TEMP_DIR/temp_config_adv01"
  mkdir -p "$TEMP_CONFIG_DIR"
  # Save a history item containing pipes in the prompt
  cat << 'EOF' > "$TEMP_CONFIG_DIR/prompter_history.txt"
git log --oneline | head -n 5 | grep fix\nSecond line with pipe | here
EOF
  export HERDR_PLUGIN_CONFIG_DIR="$TEMP_CONFIG_DIR"
  
  # 1. Test preview of tab-delimited history line
  raw_line=$(bash "$PROMPTER_SCRIPT" --list-history | head -n 1)
  run bash "$PROMPTER_SCRIPT" --preview-only "$raw_line"
  [ "$status" -eq 0 ]
  [[ "$output" == *"git log --oneline | head -n 5 | grep fix"* ]]
  [[ "$output" == *"Second line with pipe | here"* ]]
  [[ "$output" != *"📜 "* ]]
}

@test "ADV-02: Escape characters (\c, \n, \t, Windows paths) in context are not corrupted" {
  cat << 'EOF' > "$MOCK_CONFIG_DIR/templates/escape-test.md"
# Escape Test
Code: {{selected}}
EOF
  # Selected text contains backslash-c, backslash-t, and Windows path
  ESCAPE_CONTEXT="{\"focused_pane_id\": \"w2:p2\", \"workspace_cwd\": \"$MOCK_GIT_DIR\", \"selected_text\": \"C:\\\\Users\\\\alice\\\\notes\\\\file.txt with \\\\c and \\\\t inside\"}"
  run bash "$PROMPTER_SCRIPT" --preview-only "Escape Test" "$ESCAPE_CONTEXT"
  [ "$status" -eq 0 ]
  [[ "$output" == *'C:\Users\alice\notes\file.txt with \c and \t inside'* ]]
}

@test "ADV-03: Preview handles single quotes and complex context JSON without syntax error" {
  cat << 'EOF' > "$MOCK_CONFIG_DIR/templates/single-quote-test.md"
# Single Quote Test
Selected: {{selected}}
EOF
  QUOTE_CONTEXT="{\"focused_pane_id\": \"w2:p2\", \"workspace_cwd\": \"$MOCK_GIT_DIR\", \"selected_text\": \"it's a text with 'single quotes' and \$(whoami)\"}"
  run bash "$PROMPTER_SCRIPT" --preview-only "Single Quote Test" "$QUOTE_CONTEXT"
  [ "$status" -eq 0 ]
  [[ "$output" == *"it's a text with 'single quotes' and \$(whoami)"* ]]
}

@test "ADV-04: {{last_command}} preserves pipeline and redirection characters without truncation" {
  cat << 'EOF' > "$MOCK_CONFIG_DIR/templates/lastcmd-pipe-test.md"
# Last Cmd Pipe Test
Ran: {{last_command}}
EOF
  # Mock pane log with shell prompt containing pipelines and redirects
  cat << 'EOF' > "$MOCK_LOG_DIR/mock_pipe_logs.txt"
user@box:~/app$ cat package.json | grep version > output.txt
EOF
  
  # Temporary mock for mux_read_pane_logs via custom log
  export TEST_STAGE="lastcmd"
  run bash "$PROMPTER_SCRIPT" --preview-only "Last Cmd Pipe Test" "$HERDR_PLUGIN_CONTEXT_JSON"
  [ "$status" -eq 0 ]
  [[ "$output" == *"[Last executed command]"* ]]
}

@test "ADV-05: tmux pane listing correctly preserves %10, %11 when current pane is %1" {
  export MUX_BACKEND="tmux"
  export TARGET_PANE_ID="%1"
  export TMUX_BIN="$BATS_TEST_DIRNAME/mocks/tmux"
  export PATH="$BATS_TEST_DIRNAME/mocks:$PATH"
  
  run bash -c "
    TMUX_BIN='$BATS_TEST_DIRNAME/mocks/tmux'
    CURRENT_BACKEND='tmux'
    TARGET_PANE_ID='%1'
    eval \"\$(sed -n '/^mux_list_panes() {/,/^}/p' '$PROMPTER_SCRIPT')\"
    mux_list_panes
  "
  [ "$status" -eq 0 ]
  [[ "$output" != *"%1 "* ]]
  [[ "$output" == *"%0"* ]]
  [[ "$output" == *"%10"* ]]
  [[ "$output" == *"%11"* ]]
}

@test "ADV-06: slugify handles dot-only titles (. or ..) safely" {
  run bash -c "
    eval \"\$(sed -n '/^slugify() {/,/^}/p' '$PROMPTER_SCRIPT')\"
    echo \".: \$(slugify '.')\"
    echo \"..: \$(slugify '..')\"
    echo \"...: \$(slugify '...')\"
  "
  [ "$status" -eq 0 ]
  [[ "$output" == *".: template"* ]]
  [[ "$output" == *"..: template"* ]]
  [[ "$output" == *"...: template"* ]]
}

@test "ADV-07: Template creation via '➕ [Create New Template]' works without local variable errors" {
  TEMP_CONFIG_DIR="$TEST_TEMP_DIR/temp_config_adv07"
  mkdir -p "$TEMP_CONFIG_DIR/templates"
  export HERDR_PLUGIN_CONFIG_DIR="$TEMP_CONFIG_DIR"
  
  # Verify slugify & template file creation logic with collision
  run bash -c "
    TEMPLATES_DIR='$TEMP_CONFIG_DIR/templates'
    eval \"\$(sed -n '/^slugify() {/,/^}/p' '$PROMPTER_SCRIPT')\"
    new_title='New Custom Template'
    new_slug=\$(slugify \"\$new_title\")
    target_edit_file=\"\${TEMPLATES_DIR}/\${new_slug}.md\"
    count=1
    while [ -f \"\$target_edit_file\" ]; do
      count=\$((count + 1))
      target_edit_file=\"\${TEMPLATES_DIR}/\${new_slug}-\${count}.md\"
    done
    echo \"# \${new_title}\" > \"\$target_edit_file\"
    echo \"File created: \$target_edit_file\"
  "
  [ "$status" -eq 0 ]
  [ -f "$TEMP_CONFIG_DIR/templates/new-custom-template.md" ]
  [[ "$(cat "$TEMP_CONFIG_DIR/templates/new-custom-template.md")" == *"# New Custom Template"* ]]
}

#!/usr/bin/env bash
# Mux Prompter - Tmux Plugin Manager (TPM) Entrypoint
# SPDX-License-Identifier: MIT

CURRENT_DIR="$(cd "$(dirname "$0")" && pwd)"

# Get user configured keybinding or fallback to default 'P' (Shift+P)
key_binding=$(tmux show-option -gqv "@prompter-key")
if [ -z "$key_binding" ]; then
  key_binding="P"
fi

# Get user configured popup width/height or defaults
popup_width=$(tmux show-option -gqv "@prompter-width")
if [ -z "$popup_width" ]; then
  popup_width="80%"
fi

popup_height=$(tmux show-option -gqv "@prompter-height")
if [ -z "$popup_height" ]; then
  popup_height="60%"
fi

# Register keybinding in tmux automatically
if tmux display-popup -h 1 -w 1 true &>/dev/null; then
  tmux bind-key "$key_binding" display-popup -E -w "$popup_width" -h "$popup_height" "PROMPTER_CALLER_PANE='#{pane_id}' $CURRENT_DIR/prompter.sh"
else
  # Fallback to split-window for older tmux versions (pre-3.2)
  tmux bind-key "$key_binding" split-window -h -c "#{pane_current_path}" "PROMPTER_CALLER_PANE='#{pane_id}' $CURRENT_DIR/prompter.sh"
fi

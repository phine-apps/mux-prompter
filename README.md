# Mux Prompter

<p align="center">
  <b>Fuzzy-pick and inject context-aware prompts into active Herdr and tmux panes.</b>
</p>

---

**Mux Prompter** is a prompt productivity plugin for terminal multiplexers ([Herdr](https://herdr.dev) and [tmux](https://github.com/tmux/tmux)). It allows you to instantly pick and inject reusable prompt templates into your active terminal pane with a single keyboard shortcut.

Additionally, it can automatically resolve context placeholders—such as error logs, git diffs, file contents, and selected code—eliminating the hassle of manual copy-pasting when interacting with AI coding assistants.

By pressing a simple shortcut, a dynamic `fzf` UI pops up, allowing you to pick a prompt template. All context placeholders (if any) are **resolved automatically in real time**, and the finalized prompt is injected straight into your active terminal pane.

---

## ⚡ Quick Demo Flow

```text
[ Active Terminal Pane ]
  │
  ├── 1. Press shortcut (`prefix + P` / `Alt + p`) ──► [ Prompter UI (fzf) ]
  │                                                       ├── Templates> (Default)
  │                                                       ├── History>   (Ctrl-R)
  │                                                       └── All>       (Ctrl-A)
  │                                                              │
  │                                                       Select Template with Live Preview
  │                                                              │
  └── 2. Instant Injection ◄─────────────────────────────────────┘
        • Standard: Injected into input buffer for editing
        • Bang (!): Executed immediately (e.g., !Run Tests)
```

---

## ✨ Key Features

- ⚡ **Instant Prompt Launcher**: Quickly pick and insert reusable prompt templates into your terminal buffer.
- 🔍 **Interactive Fuzzy Picking**: Search templates using `fzf` with a side-by-side live resolved preview.
- 🤖 **Auto-Context Resolution**: Automatically gathers terminal logs, git diffs, branch names, file contents, and error tracebacks via `{{placeholders}}`.
- 🎯 **Interactive Inputs**: Interactively prompt for missing variables, choose target panes, or pick files on-the-fly.
- ⚡ **Immediate Execution (`!`)**: Templates starting with `!` execute immediately in the target pane without hitting Enter.
- 📜 **Prompt History**: Automatically saves sent prompts so you can re-use previous prompts easily with `Ctrl-R`.

---

## 📦 Prerequisites

Ensure you have the following CLI tools installed:

- **`fzf`**: Command-line fuzzy finder.
- **`jq`**: Command-line JSON processor.

---

## 🚀 Installation & Setup

### 🟢 Herdr Setup

1. Install via Herdr CLI:
   ```bash
   herdr plugin install phine-apps/mux-prompter
   ```

2. Add keybinding to `~/.config/herdr/config.toml`:
   ```toml
   [[keys.command]]
   key = "prefix+P"
   type = "shell"
   command = "herdr plugin pane open --plugin github.phine-apps.mux-prompter --entrypoint picker"
   ```

---

### 🔲 tmux Setup & Plugin Distribution

Mux Prompter natively supports **TPM (Tmux Plugin Manager)** for one-line installation and distribution.

#### Option A: Install via TPM (Recommended)

Add to your `~/.tmux.conf`:

```tmux
set -g @plugin 'phine-apps/mux-prompter'
```

Then press `prefix` + `I` to fetch and install the plugin automatically!

*(Optional TPM Customizations in `~/.tmux.conf`)*:
```tmux
set -g @prompter-key 'P'       # Custom shortcut key (default: P)
set -g @prompter-width '80%'   # Custom popup width (default: 80%)
set -g @prompter-height '60%'  # Custom popup height (default: 60%)
```

---

#### Option B: Manual Installation

1. **Clone Repository**:
   ```bash
   git clone https://github.com/phine-apps/mux-prompter.git ~/apps/mux-prompter
   ```

2. **Add Keybinding to `~/.tmux.conf`**:
   ```tmux
   # Bind prefix + P (Shift+P) to open Mux Prompter in a popup window
   bind-key P display-popup -E -w 80% -h 60% "~/apps/mux-prompter/prompter.sh"
   ```

---

## 💡 How to Use

### Step 1: Open Prompter UI

Press your configured shortcut key (`prefix` + `P` in tmux, or shell shortcut). The `fzf` UI overlay will appear at the top.

### Step 2: Switch Views (Optional)

Use the keyboard shortcuts shown in the top header:

- **`Ctrl-T`**: Show Prompt Templates (Default)
- **`Ctrl-R`**: Show History of previously executed prompts
- **`Ctrl-A`**: Show All (Templates + History)

### Step 3: Select Template & Confirm

As you move your selection cursor, the right preview panel dynamically displays how placeholders (like `{{git_diff}}` or `{{error}}`) will be resolved.

Press **Enter** to confirm:

- **Standard Templates**: The generated text is pasted into your active terminal pane so you can inspect or edit it before sending.
- **Immediate Executables (`!`)**: If the title starts with `!` (e.g., `!Run Tests`), it is executed immediately as a shell command.

---

## 🧩 Supported Placeholders

You can use any of the following placeholders inside your prompt templates:

### 🐙 Git & Workspace Context

| Placeholder           | Description                          | Example Output          |
| :-------------------- | :----------------------------------- | :---------------------- |
| `{{git_diff}}`        | Full `git diff` of unstaged changes  | Diff of modified files  |
| `{{git_diff:staged}}` | `git diff` of staged changes only    | Diff of staged files    |
| `{{git_status}}`      | Concise git status (`git status -s`) | ` M src/main.rs`        |
| `{{git_branch}}`      | Current active git branch name       | `main` or `feature-xyz` |

### 🖥️ Terminal & Pane Context

| Placeholder            | Description                                          | Example Output                  |
| :--------------------- | :--------------------------------------------------- | :------------------------------ |
| `{{selected}}`         | Currently selected text/code block in Herdr          | _(Selected code block)_         |
| `{{pane_logs}}`        | Last 100 lines of scrollback buffer from active pane | Terminal output                 |
| `{{pane_logs:errors}}` | Extracts error/warning lines from last 100 lines     | `Error: Connection refused`     |
| `{{last_command}}`     | Automatically parses the last executed shell command | `npm test` or `cat > /dev/null` |
| `{{error}}`            | Scans scrollback logs for recent errors/exceptions   | Stacktrace or panic log         |

### 🎯 Interactive Inputs & Choosers

| Placeholder           | Description                          | Behavior                                                                    |
| :-------------------- | :----------------------------------- | :-------------------------------------------------------------------------- |
| `{{pane:choose}}`     | Pick another pane in your workspace  | `fzf` opens showing `Tab X \| Pane ID (dir)`. Imports log of selected pane. |
| `{{panes:choose}}`    | Pick multiple panes for broadcasting | Multi-select `fzf` list to target multiple panes.                           |
| `{{file}}`            | Pick a file from repository          | `fzf` opens to select a file. Injects **full contents** of the file.        |
| `{{file_path}}`       | Pick a file from repository          | `fzf` opens to select a file. Injects **relative path** of the file.        |
| `{{file:lines=1-20}}` | Truncate specific lines from a file  | Injects lines 1 to 20 from selected file.                                   |
| `{{input}}`           | Custom multi-line prompt input       | Prompts for manual input in terminal (Ctrl+D to finish).                    |
| `{{var:name}}`        | Interactive custom variable          | Prompts for value `name` (or shows `fzf` choices if generator is defined).  |

---

## 🛠️ Customization & Configuration

Templates are loaded from `templates.txt` stored in your plugin configuration directory:
`~/.config/herdr/plugins/github.phine-apps.mux-prompter/templates.txt`

### Edit Templates via UI

Select **`⚙️ Edit Templates`** from the `fzf` UI to open `templates.txt` in your editor (`$EDITOR` or `nano`/`vi`).

### Template Syntax

Each line in `templates.txt` follows the format:

```text
Title of Template|Actual prompt template text with {{placeholders}}
```

- Add a **`!`** prefix to the title for **immediate execution** (e.g., `!Run Tests|npm test`).

### Custom Variable Candidate Generators (`$ name: command`)

You can define candidate command generators for custom variables (`{{var:name}}`) at the bottom of `templates.txt` using the `$ name: command` syntax:

```text
# Candidate generators ($ var_name: shell_command)
$ branch: git branch --format="%(refname:short)"
$ environment: echo -e "development\nstaging\nproduction"
```

When selecting a template containing `{{var:branch}}`, an `fzf` menu will automatically pop up with choices generated by `git branch`!

---

## 📝 Example `templates.txt`

````text
Summarize Discussion|Please summarize the key points of our discussion so far.
!Run Tests|npm test
Refactor Selected Code|Please refactor this code to improve readability:\n\n```\n{{selected}}\n```
Fix Terminal Error|I ran `{{last_command}}` and encountered this error:\n\n```\n{{error}}\n```\nPlease analyze and fix this.
Review Git Changes|Please review the following git changes:\n\n```\n{{git_diff}}\n```
Ask Custom Question|{{input}}

# Candidate Generators (optional)
$ branch: git branch --format="%(refname:short)"
$ environment: echo -e "development\nstaging\nproduction"
````

---

## 🔀 Hybrid Multiplexer Support (Herdr & tmux)

Mux Prompter natively supports **[Herdr](https://herdr.dev)** and **[tmux](https://github.com/tmux/tmux)** multiplexers via a unified backend abstraction layer.

### Automatic Detection

By default, Mux Prompter automatically detects which terminal multiplexer environment is currently active:
- **`tmux`**: Detected when running inside a `tmux` session (`$TMUX` environment variable is set) or when `tmux` CLI responds.
- **`herdr`**: Detected when `$HERDR_PLUGIN_CONTEXT_JSON` is present or running as a Herdr plugin entrypoint.

### Environment Overrides

You can explicitly override the backend selection by setting the `MUX_BACKEND` environment variable:

```bash
export MUX_BACKEND="tmux"   # Force tmux backend
# or
export MUX_BACKEND="herdr"  # Force Herdr backend
```

| Variable | Description | Default |
| :--- | :--- | :--- |
| `MUX_BACKEND` | `auto`, `tmux`, or `herdr` | `auto` |
| `TMUX_BIN_PATH` | Custom path to `tmux` executable | `tmux` |
| `HERDR_BIN_PATH` | Custom path to `herdr` executable | `herdr` |

---

## 📄 License

This project is licensed under the [MIT License](LICENSE).

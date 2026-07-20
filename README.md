# Mux Prompter

<p align="center">
  <b>Fuzzy-pick and inject context-aware prompts into active Herdr panes.</b>
</p>

---

**Mux Prompter** is a prompt productivity plugin for terminal multiplexers ([Herdr](https://herdr.dev)). It eliminates the manual work of copying and pasting error logs, git diffs, file contents, and selected code when interacting with AI coding assistants in your terminal.

By pressing a simple shortcut, a dynamic `fzf` UI pops up, allowing you to pick a prompt template. All context placeholders are **resolved automatically in real time**, and the finalized prompt is injected straight into your active terminal pane.

---

## ⚡ Quick Demo Flow

```text
[ Active Terminal Pane ]
  │
  ├── 1. Press `prefix + p`  ────────► [ Prompter UI (fzf) ]
  │                                       ├── Templates> (Default)
  │                                       ├── History>   (Ctrl-R)
  │                                       └── All>       (Ctrl-A)
  │                                              │
  │                                       Select Template with Live Preview
  │                                              │
  └── 2. Instant Injection ◄─────────────────────┘
        • Standard: Injected into input buffer for editing
        • Bang (!): Executed immediately (e.g., !Run Tests)
```

---

## ✨ Key Features

- 🔍 **Interactive Fuzzy Picking**: Instantly search templates using `fzf` with a side-by-side live resolved preview.
- 🤖 **Auto-Context Resolution**: Automatically gathers terminal logs, git diffs, git branch names, active file contents, and error tracebacks.
- 🎯 **Interactive Inputs**: Interactively prompt for missing variables, choose target panes, or pick files on-the-fly.
- ⚡ **Immediate Execution (`!`)**: Templates starting with `!` execute immediately in the target pane without hitting Enter.
- 📜 **Prompt History**: Automatically saves sent prompts so you can re-use or tweak previous prompts easily with `Ctrl-R`.

---

## 📦 Prerequisites

Ensure you have the following CLI tools installed:

- **`fzf`**: Command-line fuzzy finder.
- **`jq`**: Command-line JSON processor.

---

## 🚀 Installation & Setup

### 1. Install Plugin

Install the plugin via Herdr CLI:

```bash
herdr plugin install phine-apps/mux-prompter
```

### 2. Configure Keybinding (Recommended)

Add a shortcut key (e.g., `prefix` + `p`) to your Herdr configuration (`~/.config/herdr/config.toml`):

```toml
[[keys.command]]
key = "prefix+p"
type = "shell"
command = "herdr plugin pane open --plugin github.phine-apps.mux-prompter --entrypoint picker"
```

---

## 💡 How to Use

### Step 1: Open Prompter UI

Press your configured shortcut key (`prefix` + `p`). The `fzf` UI overlay will appear at the top.

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
Fix Terminal Error|I ran `{{last_command}}` and encountered this error:\n\n```\n{{error}}\n```\nPlease analyze and fix this.
Review Other Pane Logs|Please analyze the logs from the selected pane:\n\n```\n{{pane:choose}}\n```
Refactor Selected Code|Please refactor this code to improve readability:\n\n```\n{{selected}}\n```
Review File Content|Please review the contents of this file:\n\n```\n{{file}}\n```
Lint Specific File|!npx eslint {{file_path}}
Deploy Component|Deploying {{var:component}} to {{var:environment}} on branch {{var:branch}}.
Ask Custom Question|{{input}}
!Run Git Status|git status
!Run Tests|npm test

# Candidate Generators
$ branch: git branch --format="%(refname:short)"
$ environment: echo -e "development\nstaging\nproduction"
````

---

## 📄 License

This project is licensed under the [MIT License](LICENSE).

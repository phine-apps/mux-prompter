#!/usr/bin/env python3
"""
End-to-End (E2E) test suite for mux-prompter using real multiplexers
(tmux, Zellij, Herdr) and real fzf over PTY.

Usage:
  python3 tests/e2e_test.py [--backend all|tmux|zellij|herdr] [--verbose]
"""

from __future__ import annotations

import argparse
import fcntl
import json
import os
import pty
import re
import select
import shutil
import signal
import struct
import subprocess
import sys
import tempfile
import termios
import time
from collections.abc import Callable
from contextlib import suppress
from pathlib import Path

REPO_ROOT = Path(__file__).resolve().parent.parent
PROMPTER_SCRIPT = REPO_ROOT / "prompter.sh"

ANSI_RE = re.compile(
    r"\x1b\][^\x07\x1b]*(?:\x07|\x1b\\)"  # OSC sequences
    r"|\x1b\[[0-9;?]*[A-Za-z@]"  # CSI sequences
    r"|\x1b[()][A-Za-z0-9]"  # Charset switches
    r"|\x1b[=>]"  # Keypad mode
)


def strip_ansi(text: str) -> str:
    """Remove terminal escape sequences while keeping printable text readable."""
    return ANSI_RE.sub("", text).replace("\r", "\n")


def clean_env(extra: dict[str, str] | None = None) -> dict[str, str]:
    """Build an environment stripped of inherited multiplexer state."""
    env = os.environ.copy()
    for key in list(env.keys()):
        if key.startswith(("TMUX", "ZELLIJ", "HERDR_", "PROMPTER_")) or key in (
            "MUX_BACKEND",
            "VISUAL",
            "EDITOR",
        ):
            env.pop(key, None)
    if "herdr" in env.get("SSH_AUTH_SOCK", "").lower():
        env.pop("SSH_AUTH_SOCK", None)
    env["SHELL"] = shutil.which("bash") or "/bin/bash"
    if not env.get("TERM") or env.get("TERM") == "dumb":
        env["TERM"] = "xterm-256color"
    if extra:
        env.update(extra)
    return env


class PTYController:
    """Interactive PTY harness for driving real fzf and terminal multiplexers."""

    def __init__(
        self,
        cmd: list[str],
        env: dict[str, str],
        cwd: str | None = None,
        rows: int = 36,
        cols: int = 120,
        verbose: bool = False,
    ) -> None:
        self.verbose = verbose
        self.master, slave = pty.openpty()
        winsize = struct.pack("HHHH", rows, cols, 0, 0)
        fcntl.ioctl(slave, termios.TIOCSWINSZ, winsize)

        self.proc = subprocess.Popen(
            cmd,
            stdin=slave,
            stdout=slave,
            stderr=slave,
            env=env,
            cwd=cwd,
            start_new_session=True,
        )
        os.close(slave)
        self.raw_buf = ""
        self.clean_buf = ""

    def drain(self, wait_s: float = 0.05) -> str:
        """Read any currently available PTY bytes without blocking indefinitely."""
        chunks: list[bytes] = []
        deadline = time.monotonic() + wait_s
        while True:
            remaining = max(0.0, deadline - time.monotonic())
            rlist, _, _ = select.select([self.master], [], [], remaining)
            if not rlist:
                break
            try:
                data = os.read(self.master, 8192)
            except OSError:
                break
            if not data:
                break
            chunks.append(data)
            deadline = time.monotonic() + 0.02

        if not chunks:
            return ""
        text = b"".join(chunks).decode("utf-8", errors="replace")
        self.raw_buf += text
        stripped = strip_ansi(text)
        self.clean_buf += stripped
        if self.verbose and stripped.strip():
            print(f"[PTY] {stripped!r}", file=sys.stderr)
        return stripped

    def mark(self) -> int:
        """Drain pending bytes and return an offset marker into clean_buf."""
        self.drain(0.05)
        return len(self.clean_buf)

    def wait_for(
        self,
        needle: str,
        timeout: float = 12.0,
        since: int = 0,
        settle: float = 0.12,
    ) -> str:
        """Wait until `needle` appears in clean output after offset `since`."""
        deadline = time.monotonic() + timeout
        while time.monotonic() < deadline:
            self.drain(0.08)
            segment = self.clean_buf[since:]
            if needle in segment:
                if settle > 0:
                    time.sleep(settle)
                    self.drain(0.05)
                return self.clean_buf[since:]
            if self.proc.poll() is not None:
                self.drain(0.05)
                segment = self.clean_buf[since:]
                if needle in segment:
                    return segment
                raise AssertionError(
                    f"Process exited ({self.proc.returncode}) before '{needle}' appeared.\n"
                    f"Recent output:\n{self.clean_buf[-1500:]}"
                )
        raise AssertionError(
            f"Timed out after {timeout}s waiting for '{needle}'.\n"
            f"Recent output:\n{self.clean_buf[-1500:]}"
        )

    def send(self, text: str, delay_after: float = 0.05) -> None:
        """Write raw keystrokes or text to the PTY master."""
        os.write(self.master, text.encode("utf-8"))
        if delay_after > 0:
            time.sleep(delay_after)

    def send_and_mark(self, text: str, delay_after: float = 0.05) -> int:
        """Capture buffer offset immediately before sending keystrokes."""
        self.drain(0.02)
        pos = len(self.clean_buf)
        self.send(text, delay_after=delay_after)
        return pos

    def fzf_pick(
        self,
        query: str,
        header_wait: str = "Templates>",
        since: int = 0,
        timeout: float = 12.0,
    ) -> int:
        """Wait for an fzf prompt/header, filter by query, press Enter, and return pre-Enter buffer offset."""
        self.wait_for(header_wait, timeout=timeout, since=since, settle=0.15)
        if query:
            self.send(query, delay_after=0.22)
        return self.send_and_mark("\r", delay_after=0.1)

    def wait_exit(self, timeout: float = 10.0) -> int:
        """Wait for the PTY child process to exit while draining output."""
        deadline = time.monotonic() + timeout
        while time.monotonic() < deadline:
            self.drain(0.08)
            rc = self.proc.poll()
            if rc is not None:
                self.drain(0.05)
                return rc
        raise AssertionError(
            f"Timed out waiting for PTY process exit.\nRecent output:\n{self.clean_buf[-1200:]}"
        )

    def close(self) -> None:
        """Close PTY master and ensure child process is stopped."""
        if self.proc.poll() is None:
            try:
                self.proc.terminate()
                self.proc.wait(timeout=2.0)
            except (subprocess.SubprocessError, OSError):
                with suppress(OSError):
                    self.proc.kill()
        with suppress(OSError):
            os.close(self.master)


def setup_git_workspace(ws_dir: Path) -> None:
    """Create a realistic Git repo with branch, staged diff, unstaged diff, and sample file."""
    ws_dir.mkdir(parents=True, exist_ok=True)
    src_dir = ws_dir / "src"
    src_dir.mkdir(exist_ok=True)

    def git(*args: str) -> None:
        r = subprocess.run(
            ["git", *args],
            cwd=str(ws_dir),
            capture_output=True,
            text=True,
            check=True,
        )
        _ = r

    git("init", "-b", "main")
    git("config", "user.email", "e2e@example.com")
    git("config", "user.name", "E2E Runner")

    (src_dir / "sample.txt").write_text(
        "line1\nline2_target\nline3_target\nline4\n", encoding="utf-8"
    )
    (ws_dir / "app.txt").write_text("base_line\n", encoding="utf-8")
    git("add", ".")
    git("commit", "-m", "initial")
    git("checkout", "-b", "feat/e2e-check")

    (ws_dir / "app.txt").write_text("base_line\nSTAGED_E2E_LINE\n", encoding="utf-8")
    git("add", "app.txt")
    (ws_dir / "app.txt").write_text(
        "base_line\nSTAGED_E2E_LINE\nUNSTAGED_E2E_LINE\n", encoding="utf-8"
    )


def setup_templates(cfg_dir: Path) -> None:
    """Populate templates and _vars.txt for E2E scenarios."""
    tpl_dir = cfg_dir / "templates"
    sub_dir = tpl_dir / "git"
    tpl_dir.mkdir(parents=True, exist_ok=True)
    sub_dir.mkdir(parents=True, exist_ok=True)

    (tpl_dir / "_vars.txt").write_text(
        "$ branch: git branch --format='%(refname:short)'\n",
        encoding="utf-8",
    )

    templates = {
        "bang-no-exec.md": "# !E2E Bang No Exec\nprintf '__EXECUTED_BANG__\\n'\n",
        "safe-symbols.md": '# E2E Safe Symbols\n日本語テスト "quoted" $HOME \\path | pipe !bang\n',
        "git-context.md": (
            "# E2E Git Context\n"
            "BR={{git_branch}}\n"
            "ST={{git_status}}\n"
            "UNSTAGED:\n{{git_diff}}\n"
            "STAGED_ONLY:\n{{git_diff:staged}}\n"
        ),
        "logs-errors.md": (
            "# E2E Logs Errors\n"
            "FULL_LOGS:\n{{pane_logs}}\n"
            "ERR_AUTO:\n{{error}}\n"
            "ERR_FILTER:\n{{pane_logs:errors}}\n"
        ),
        "manual-fallback.md": "# E2E Manual Fallback\nCMD={{last_command}}\nERR={{error}}\n",
        "vars-files-input.md": (
            "# E2E Vars Files Input\n"
            "BR_VAR={{var:branch}}\n"
            "NOTE={{var:manual_note}}\n"
            "IN={{input}}\n"
            "PATH={{file_path}}\n"
            "RANGE={{file:lines=2-3}}\n"
            "FULL={{file}}\n"
        ),
        "cross-pane-logs.md": "# E2E Cross Pane Logs\n-imported-logs:\n{{pane:choose}}\n",
        "broadcast-panes.md": "# E2E Broadcast Panes\n-broadcast-msg {{panes:choose}}\n",
        "history-base.md": "# E2E History Base\nHISTORY_PAYLOAD_ALPHA\n",
        "git/sub-review.md": "# E2E Subfolder Review\nSUBFOLDER_OK {{git_branch}}\n",
    }
    for rel_path, body in templates.items():
        (tpl_dir / rel_path).write_text(body, encoding="utf-8")


def wait_for_condition(
    predicate: Callable[[], bool],
    timeout: float = 10.0,
    interval: float = 0.1,
    desc: str = "condition",
) -> None:
    """Poll predicate until truthy or raise AssertionError."""
    deadline = time.monotonic() + timeout
    while time.monotonic() < deadline:
        if predicate():
            return
        time.sleep(interval)
    raise AssertionError(f"Timed out waiting for {desc}")


class RunnerStats:
    """Track pass/fail/skip outcomes across suites."""

    def __init__(self) -> None:
        self.results: list[tuple[str, str, str]] = []

    def record(self, status: str, name: str, detail: str = "") -> None:
        self.results.append((status, name, detail))
        suffix = f" ({detail})" if detail else ""
        print(f"[{status}] {name}{suffix}", flush=True)

    def run_case(self, name: str, fn: Callable[[], None]) -> None:
        try:
            fn()
            self.record("PASS", name)
        except Exception as exc:  # noqa: BLE001
            self.record("FAIL", name, str(exc))

    def has_failures(self) -> bool:
        return any(s == "FAIL" for s, _, _ in self.results)

    def summary(self) -> int:
        passed = sum(1 for s, _, _ in self.results if s == "PASS")
        failed = sum(1 for s, _, _ in self.results if s == "FAIL")
        skipped = sum(1 for s, _, _ in self.results if s == "SKIP")
        print(
            f"\nE2E Summary: {passed} passed, {failed} failed, {skipped} skipped",
            flush=True,
        )
        return 1 if failed else 0


# ---------------------------------------------------------------------------
# tmux E2E Suite
# ---------------------------------------------------------------------------


def run_tmux_e2e(stats: RunnerStats, verbose: bool) -> None:
    if not shutil.which("tmux"):
        stats.record("SKIP", "TMUX-E2E", "tmux binary not found")
        return

    tmp = Path(tempfile.mkdtemp(prefix="mxp_e2e_tmux_"))
    sock = f"mxp-e2e-{os.getpid()}"
    ws_dir = tmp / "ws"
    other_dir = tmp / "other"
    cfg_dir = tmp / "cfg"
    other_dir.mkdir(parents=True, exist_ok=True)
    setup_git_workspace(ws_dir)
    setup_templates(cfg_dir)

    tmux_conf = tmp / "tmux.conf"
    # Fake EDITOR script for T-03 (Edit Templates creation test) and E-02 (killed editor)
    editor_ok = tmp / "fake_editor_ok.sh"
    editor_ok.write_text(
        "#!/usr/bin/env bash\nprintf '\\nCREATED_BY_E2E_EDITOR\\n' >> \"$1\"\n",
        encoding="utf-8",
    )
    editor_ok.chmod(0o755)

    editor_kill = tmp / "fake_editor_kill.sh"
    editor_kill.write_text(
        "#!/usr/bin/env bash\nkill -9 $$\n",
        encoding="utf-8",
    )
    editor_kill.chmod(0o755)

    tmux_conf.write_text(
        'set -g default-command "bash --norc --noprofile"\n'
        "set -sg escape-time 10\n"
        "set -sg assume-paste-time 0\n"
        f"bind-key P display-popup -E -w 85% -h 70% "
        f"\"PROMPTER_CALLER_PANE='#{{pane_id}}' HERDR_PLUGIN_CONFIG_DIR='{cfg_dir}' "
        f"VISUAL='' EDITOR='{editor_ok}' bash '{PROMPTER_SCRIPT}'\"\n",
        encoding="utf-8",
    )

    base_env = clean_env({"HERDR_PLUGIN_CONFIG_DIR": str(cfg_dir)})

    def tmux(*args: str, check: bool = True) -> subprocess.CompletedProcess[str]:
        res = subprocess.run(
            ["tmux", "-L", sock, "-f", str(tmux_conf), *args],
            check=False,
            capture_output=True,
            text=True,
            env=base_env,
        )
        if check and res.returncode != 0:
            raise RuntimeError(
                f"tmux {' '.join(args)} failed (rc={res.returncode}): "
                f"stderr={res.stderr.strip()!r} stdout={res.stdout.strip()!r}"
            )
        return res

    client: PTYController | None = None
    try:
        # Start isolated tmux server with Window 0 (git ws) and Window 1 (other ws)
        tmux(
            "new-session", "-d", "-s", "e2e", "-x", "120", "-y", "36", "-c", str(ws_dir)
        )
        p0 = tmux("display-message", "-p", "#{pane_id}").stdout.strip()
        tmux("new-window", "-t", "e2e", "-c", str(other_dir))
        p1 = tmux("display-message", "-p", "#{pane_id}").stdout.strip()
        tmux("select-window", "-t", "e2e:0")

        # Configure clean prompt with ignoreeof in both panes
        for pid in (p0, p1):
            tmux("send-keys", "-t", pid, "set -o ignoreeof; PS1='READY> '", "Enter")
        wait_for_condition(
            lambda: "READY>" in tmux("capture-pane", "-t", p0, "-p").stdout,
            desc="tmux pane 0 prompt",
        )
        wait_for_condition(
            lambda: "READY>" in tmux("capture-pane", "-t", p1, "-p").stdout,
            desc="tmux pane 1 prompt",
        )

        # Emit distinct log in p1 for cross-pane import
        tmux("send-keys", "-t", p1, "echo OTHER_PANE_LOG_99", "Enter")
        wait_for_condition(
            lambda: "OTHER_PANE_LOG_99" in tmux("capture-pane", "-t", p1, "-p").stdout,
            desc="p1 log emission",
        )

        # Attach real PTY client so tmux display-popup & fzf operate on real TTY
        client = PTYController(
            ["tmux", "-L", sock, "attach-session", "-t", "e2e"],
            env=base_env,
            cwd=str(ws_dir),
            verbose=verbose,
        )
        client.wait_for("READY>", timeout=10.0)
        client.wait_for("0:bash", timeout=10.0, settle=0.3)

        def send_popup_trigger() -> int:
            mark = client.mark()
            client.send("\x02", delay_after=0.08)  # prefix (Ctrl-B)
            client.send("P", delay_after=0.05)
            return mark

        def open_popup_and_pick(query: str) -> int:
            mark = send_popup_trigger()
            return client.fzf_pick(query, header_wait="Templates>", since=mark)

        def start_cat_capture(pane_id: str, out_file: Path) -> None:
            # Non-canonical mode flushes every byte immediately without requiring newline or Ctrl-D
            tmux("send-keys", "-t", pane_id, "C-u")
            tmux(
                "send-keys",
                "-t",
                pane_id,
                f"stty -echo -icanon min 1 time 0; cat > '{out_file}'; stty sane",
                "Enter",
            )
            time.sleep(0.25)

        def finish_cat_capture(pane_id: str, out_file: Path) -> str:
            wait_for_condition(
                lambda: out_file.exists() and out_file.stat().st_size > 0,
                timeout=8.0,
                desc=f"cat capture {out_file.name}",
            )
            time.sleep(0.25)
            tmux("send-keys", "-t", pane_id, "C-c")
            wait_for_condition(
                lambda: (
                    "READY>"
                    in (
                        [
                            ln
                            for ln in tmux(
                                "capture-pane", "-t", pane_id, "-p"
                            ).stdout.splitlines()
                            if ln.strip()
                        ]
                        or [""]
                    )[-1]
                ),
                timeout=6.0,
                desc=f"shell return in {pane_id}",
            )
            return out_file.read_text(encoding="utf-8", errors="replace")

        def case_01_bang_and_symbols() -> None:
            # 1) !Bang title must NOT execute command automatically on shell prompt
            open_popup_and_pick("E2E Bang No Exec")
            wait_for_condition(
                lambda: (
                    "__EXECUTED_BANG__" in tmux("capture-pane", "-t", p0, "-p").stdout
                ),
                desc="bang command inserted into buffer",
            )
            time.sleep(0.3)
            captured_lines = tmux("capture-pane", "-t", p0, "-p").stdout.splitlines()
            # Ensure it sits in input line (READY> ...) and did NOT print standalone output
            assert not any(
                line.strip() == "__EXECUTED_BANG__" for line in captured_lines
            ), f"Bang template auto-executed unexpectedly: {captured_lines}"
            tmux("send-keys", "-t", p0, "C-c")
            time.sleep(0.15)

            # 2) Special symbols & Japanese multibyte exact insertion via cat
            out = tmp / "p01_symbols.txt"
            start_cat_capture(p0, out)
            open_popup_and_pick("E2E Safe Symbols")
            text = finish_cat_capture(p0, out)
            assert '日本語テスト "quoted" $HOME \\path | pipe !bang' in text, (
                f"Got: {text!r}"
            )

        def case_02_git_context() -> None:
            out = tmp / "p02_git.txt"
            start_cat_capture(p0, out)
            open_popup_and_pick("E2E Git Context")
            text = finish_cat_capture(p0, out)
            assert "BR=feat/e2e-check" in text, text
            assert "app.txt" in text, text
            unstaged_part, staged_part = text.split("STAGED_ONLY:", 1)
            assert "UNSTAGED_E2E_LINE" in unstaged_part, text
            assert "STAGED_E2E_LINE" in staged_part, text
            assert "UNSTAGED_E2E_LINE" not in staged_part, (
                f"Staged diff leaked unstaged: {text}"
            )

        def case_03_logs_errors_and_manual_fallback() -> None:
            tmux(
                "send-keys",
                "-t",
                p0,
                "printf '\\033[31mERROR: tmux_e2e_fail_42\\033[0m\\n'",
                "Enter",
            )
            wait_for_condition(
                lambda: (
                    "tmux_e2e_fail_42" in tmux("capture-pane", "-t", p0, "-p").stdout
                ),
                desc="p0 colored error output",
            )
            out = tmp / "p03_logs.txt"
            start_cat_capture(p0, out)
            open_popup_and_pick("E2E Logs Errors")
            text = finish_cat_capture(p0, out)
            assert "\x1b[" not in text, f"ANSI escape was not stripped: {text!r}"
            assert "ERROR: tmux_e2e_fail_42" in text, text

            # Manual fallback for {{last_command}} when pane history has no prompt sigils ($, %, #)
            tmux("new-window", "-t", "e2e", "-c", str(other_dir))
            p2 = tmux("display-message", "-p", "#{pane_id}").stdout.strip()
            try:
                tmux("send-keys", "-t", p2, "set -o ignoreeof; PS1='NO_SIG '", "Enter")
                wait_for_condition(
                    lambda: "NO_SIG " in tmux("capture-pane", "-t", p2, "-p").stdout,
                    desc="p2 NO_SIG prompt",
                )
                tmux("send-keys", "-t", p2, "C-l")
                time.sleep(0.1)
                tmux("clear-history", "-t", p2)
                tmux("select-window", "-t", "e2e:0")

                p_pty = PTYController(
                    ["bash", str(PROMPTER_SCRIPT)],
                    env={
                        **base_env,
                        "TMUX": tmux(
                            "display-message", "-p", "#{socket_path},#{pid},0"
                        ).stdout.strip(),
                        "PROMPTER_TARGET_PANE": p2,
                    },
                    cwd=str(ws_dir),
                    verbose=verbose,
                )
                try:
                    m0 = p_pty.mark()
                    m0 = p_pty.fzf_pick(
                        "E2E Manual Fallback", header_wait="Templates>", since=m0
                    )
                    p_pty.wait_for("Enter the command manually", since=m0)
                    p_pty.send("make test-manual\r", delay_after=0.1)
                    rc = p_pty.wait_exit(timeout=10.0)
                    assert rc == 0
                finally:
                    p_pty.close()
                wait_for_condition(
                    lambda: (
                        "CMD=make test-manual"
                        in tmux("capture-pane", "-t", p2, "-p").stdout
                    ),
                    desc="manual last_command inserted into p2",
                )
            finally:
                tmux("kill-pane", "-t", p2, check=False)

        def case_04_vars_files_input() -> None:
            out = tmp / "p04_vars.txt"
            start_cat_capture(p0, out)
            m = open_popup_and_pick("E2E Vars Files Input")
            # 1) {{var:branch}} opens fzf candidates from _vars.txt
            m = client.fzf_pick(
                "feat/e2e-check", header_wait="Select value for branch", since=m
            )
            # 2) {{var:manual_note}} prompts on terminal
            client.wait_for("Enter value for [manual_note]:", since=m)
            m = client.send_and_mark("typed_note_abc\r", delay_after=0.1)
            # 3) {{input}} multi-line input ended by Ctrl-D
            client.wait_for("Enter your custom question/prompt", since=m)
            m = client.send_and_mark(
                "multi_line_1\nmulti_line_2\n\x04", delay_after=0.15
            )
            # 4) prompter.sh resolves {{file:lines=...}}, {{file}}, then {{file_path}} in that order
            for hdr in (
                "Select a file to insert (lines 2-3):",
                "Select a file to insert (Git Root:",
                "Select a file to insert path:",
            ):
                m = client.fzf_pick("src/sample.txt", header_wait=hdr, since=m)

            text = finish_cat_capture(p0, out)
            assert "BR_VAR=feat/e2e-check" in text, text
            assert "NOTE=typed_note_abc" in text, text
            assert "multi_line_1\nmulti_line_2" in text, text
            assert "PATH=src/sample.txt" in text, text
            assert "RANGE=line2_target\nline3_target" in text, text
            assert "FULL=line1\nline2_target\nline3_target\nline4" in text, text

        def case_05_cross_pane_and_broadcast() -> None:
            # 1) {{pane:choose}} imports logs from Window 1 (1.0 | %1) into caller pane (p0)
            out0 = tmp / "p05_choose.txt"
            start_cat_capture(p0, out0)
            m = open_popup_and_pick("E2E Cross Pane Logs")
            client.fzf_pick(
                p1, header_wait="Select a pane to import logs from:", since=m
            )
            text = finish_cat_capture(p0, out0)
            assert "-imported-logs:" in text, text
            assert "OTHER_PANE_LOG_99" in text, text

            # 2) {{panes:choose}} multi-select with Tab across p0 and p1
            out_b0 = tmp / "p05_b0.txt"
            out_b1 = tmp / "p05_b1.txt"
            start_cat_capture(p0, out_b0)
            start_cat_capture(p1, out_b1)
            m = open_popup_and_pick("E2E Broadcast Panes")
            client.wait_for("Select target panes for broadcast", since=m, settle=0.15)
            client.wait_for(p1, since=m, settle=0.1)
            # Tab twice (auto-advances cursor in fzf -m) then Enter
            client.send("\t", delay_after=0.12)
            client.send("\t", delay_after=0.12)
            client.send("\r", delay_after=0.15)
            res0 = finish_cat_capture(p0, out_b0)
            res1 = finish_cat_capture(p1, out_b1)
            assert "-broadcast-msg" in res0, res0
            assert "-broadcast-msg" in res1, res1

        def case_06_views_history_and_cancel() -> None:
            # First inject HISTORY_PAYLOAD_ALPHA so history has multiple entries and an older item
            out_h = tmp / "p06_hist.txt"
            start_cat_capture(p0, out_h)
            open_popup_and_pick("E2E History Base")
            assert "HISTORY_PAYLOAD_ALPHA" in finish_cat_capture(p0, out_h)

            # Inject Safe Symbols after it so HISTORY_PAYLOAD_ALPHA becomes older (2nd line)
            out_s = tmp / "p06_safe.txt"
            start_cat_capture(p0, out_s)
            open_popup_and_pick("E2E Safe Symbols")
            finish_cat_capture(p0, out_s)

            # Open popup, verify Ctrl-R -> Ctrl-A -> Ctrl-T switching, then Esc cancel
            m = send_popup_trigger()
            client.wait_for("Templates>", since=m, settle=0.15)
            m = client.send_and_mark("\x12", delay_after=0.15)  # Ctrl-R -> History>
            client.wait_for("History>", since=m, settle=0.1)
            m = client.send_and_mark("\x01", delay_after=0.15)  # Ctrl-A -> All>
            client.wait_for("All>", since=m, settle=0.1)
            m = client.send_and_mark("\x14", delay_after=0.15)  # Ctrl-T -> Templates>
            client.wait_for("Templates>", since=m, settle=0.1)
            client.send("\x1b", delay_after=0.35)  # Esc cancels safely
            client.drain(0.1)

            # Re-open, Ctrl-R, pick HISTORY_PAYLOAD_ALPHA, confirm injection & promotion to top of history
            out_re = tmp / "p06_reuse.txt"
            start_cat_capture(p0, out_re)
            m = send_popup_trigger()
            client.wait_for("Templates>", since=m, settle=0.15)
            m = client.send_and_mark("\x12", delay_after=0.15)
            client.fzf_pick("HISTORY_PAYLOAD_ALPHA", header_wait="History>", since=m)
            re_text = finish_cat_capture(p0, out_re)
            assert "HISTORY_PAYLOAD_ALPHA" in re_text, re_text
            top_hist = (
                (cfg_dir / "prompter_history.txt")
                .read_text(encoding="utf-8")
                .splitlines()[0]
            )
            assert "HISTORY_PAYLOAD_ALPHA" in top_hist, (
                f"Not promoted to top: {top_hist}"
            )

        def case_07_template_management_and_tty_recovery() -> None:
            # 1) Subfolder template works
            out_sub = tmp / "p07_sub.txt"
            start_cat_capture(p0, out_sub)
            open_popup_and_pick("E2E Subfolder Review")
            sub_text = finish_cat_capture(p0, out_sub)
            assert "SUBFOLDER_OK feat/e2e-check" in sub_text, (
                f"Subfolder output mismatch: {sub_text!r}"
            )

            # 2) Edit Templates -> Create -> Reload -> Ctrl-D N (keep) -> Ctrl-D y (delete) -> Esc
            m = open_popup_and_pick("Edit Templates")
            m = client.fzf_pick(
                "Create New Template", header_wait="[Enter] Edit", since=m
            )
            client.wait_for("Enter new template title", since=m)
            m = client.send_and_mark("Dynamic Created Tpl\r", delay_after=0.25)

            # Editor adds CREATED_BY_E2E_EDITOR and exits -> returns to main Templates> menu
            created_md = cfg_dir / "templates" / "dynamic-created-tpl.md"
            wait_for_condition(
                lambda: (
                    created_md.exists()
                    and "CREATED_BY_E2E_EDITOR"
                    in created_md.read_text(encoding="utf-8")
                ),
                desc="created template modified by editor",
            )

            # Re-enter Edit Templates, press Ctrl-D on dynamic template -> answer 'N' (kept), then 'y' (deleted)
            m = client.fzf_pick("Edit Templates", header_wait="Templates>", since=m)
            client.wait_for("[Enter] Edit", since=m, settle=0.15)
            client.send("Dynamic Created Tpl", delay_after=0.2)
            m = client.send_and_mark("\x04", delay_after=0.1)  # Ctrl-D
            client.wait_for("Delete template", since=m)
            m = client.send_and_mark("N\r", delay_after=0.15)
            assert created_md.exists(), "N confirmation deleted file unexpectedly"

            # After confirmation, prompter loops back to main Templates> menu; re-enter Edit Templates to delete
            m = client.fzf_pick("Edit Templates", header_wait="Templates>", since=m)
            client.wait_for("[Enter] Edit", since=m, settle=0.15)
            client.send("Dynamic Created Tpl", delay_after=0.2)
            m = client.send_and_mark("\x04", delay_after=0.1)
            client.wait_for("Delete template", since=m)
            m = client.send_and_mark("y\r", delay_after=0.2)
            wait_for_condition(
                lambda: not created_md.exists(), desc="template deleted on y"
            )

            # After deletion, prompter loops back to main Templates> -> Esc exits
            client.wait_for("Templates>", since=m, settle=0.15)
            client.send("\x1b", delay_after=0.25)

            # 3) E-02: Killed editor does not break TTY / fzf recovery
            sock_str = tmux(
                "display-message", "-p", "#{socket_path},#{pid},0"
            ).stdout.strip()
            e2_pty = PTYController(
                ["bash", str(PROMPTER_SCRIPT)],
                env={
                    **base_env,
                    "TMUX": sock_str,
                    "PROMPTER_TARGET_PANE": p0,
                    "VISUAL": "",
                    "EDITOR": str(editor_kill),
                },
                cwd=str(ws_dir),
                verbose=verbose,
            )
            try:
                m = e2_pty.fzf_pick("Edit Templates", header_wait="Templates>", since=0)
                m = e2_pty.fzf_pick(
                    "E2E Safe Symbols", header_wait="[Enter] Edit", since=m
                )
                # After SIGKILL, prompter loops back and renders Templates> cleanly on intact TTY
                e2_pty.wait_for("Templates>", since=m, timeout=8.0, settle=0.1)
                e2_pty.send("\x1b", delay_after=0.1)
                rc = e2_pty.wait_exit(timeout=6.0)
                assert rc == 0, f"e2_pty exited with rc={rc}"
            finally:
                e2_pty.close()

        def case_08_fullscreen_tui_and_backend_override() -> None:
            # Open full-screen `less` inside p0, inject via MUX_BACKEND=tmux without hang
            sample_view = tmp / "view_file.txt"
            sample_view.write_text(
                "LESS_SCREEN_TOP\n" + "\n".join(f"line {i}" for i in range(60)),
                encoding="utf-8",
            )
            tmux("send-keys", "-t", p0, f"less '{sample_view}'", "Enter")
            wait_for_condition(
                lambda: (
                    "LESS_SCREEN_TOP" in tmux("capture-pane", "-t", p0, "-p").stdout
                ),
                desc="less started in p0",
            )
            sock_str = tmux(
                "display-message", "-p", "#{socket_path},#{pid},0"
            ).stdout.strip()
            e1_pty = PTYController(
                ["bash", str(PROMPTER_SCRIPT)],
                env={
                    **base_env,
                    "TMUX": sock_str,
                    "MUX_BACKEND": "tmux",
                    "PROMPTER_TARGET_PANE": p0,
                },
                cwd=str(ws_dir),
                verbose=verbose,
            )
            try:
                e1_pty.fzf_pick("E2E Safe Symbols", header_wait="Templates>", since=0)
                rc = e1_pty.wait_exit(timeout=8.0)
                assert rc == 0, f"prompter hung or failed on less pane: rc={rc}"
            finally:
                e1_pty.close()
                tmux("send-keys", "-t", p0, "q")
                wait_for_condition(
                    lambda: "READY>" in tmux("capture-pane", "-t", p0, "-p").stdout,
                    desc="less exited cleanly",
                )

        def reset_tmux_panes(close_popup: bool = False) -> None:
            if close_popup:
                client.send("\x1b", delay_after=0.15)
            client.drain(0.05)
            for pid in (p0, p1):
                tmux("send-keys", "-t", pid, "C-c", check=False)
                time.sleep(0.05)

        for name, fn in (
            (
                "TMUX-E2E-01 (Popup bind, !No-Auto-Enter, Multibyte & Symbols)",
                case_01_bang_and_symbols,
            ),
            (
                "TMUX-E2E-02 (Git unstaged/staged diff, status, branch)",
                case_02_git_context,
            ),
            (
                "TMUX-E2E-03 (ANSI strip, error extract, manual fallback)",
                case_03_logs_errors_and_manual_fallback,
            ),
            (
                "TMUX-E2E-04 (_vars.txt fzf, {{input}}, {{file}} / lines)",
                case_04_vars_files_input,
            ),
            (
                "TMUX-E2E-05 ({{pane:choose}} & {{panes:choose}} broadcast)",
                case_05_cross_pane_and_broadcast,
            ),
            (
                "TMUX-E2E-06 (Ctrl-R/A/T views, History reuse, Esc cancel)",
                case_06_views_history_and_cancel,
            ),
            (
                "TMUX-E2E-07 (Subfolder, Edit Create/Delete/Keep, E-02 TTY)",
                case_07_template_management_and_tty_recovery,
            ),
            (
                "TMUX-E2E-08 (Full-screen TUI target, MUX_BACKEND=tmux)",
                case_08_fullscreen_tui_and_backend_override,
            ),
        ):
            stats.run_case(name, fn)
            case_failed = bool(stats.results) and stats.results[-1][0] == "FAIL"
            reset_tmux_panes(close_popup=case_failed)
    finally:
        if client is not None:
            client.close()
        subprocess.run(
            ["tmux", "-L", sock, "kill-server"],
            check=False,
            capture_output=True,
            env=base_env,
        )
        shutil.rmtree(tmp, ignore_errors=True)


# ---------------------------------------------------------------------------
# Zellij E2E Suite
# ---------------------------------------------------------------------------


def run_zellij_e2e(stats: RunnerStats, verbose: bool) -> None:
    if not shutil.which("zellij"):
        stats.record("SKIP", "ZELLIJ-E2E", "zellij binary not found")
        return

    tmp = Path(tempfile.mkdtemp(prefix="mxp_e2e_zj_"))
    sess = f"mxp-e2e-zj-{os.getpid()}"
    ws_dir = tmp / "ws"
    other_dir = tmp / "other"
    cfg_dir = tmp / "cfg"
    other_dir.mkdir(parents=True, exist_ok=True)
    setup_git_workspace(ws_dir)
    setup_templates(cfg_dir)

    cfg_kdl = tmp / "config.kdl"
    cfg_kdl.write_text('default_shell "bash"\n', encoding="utf-8")

    env = clean_env({"HERDR_PLUGIN_CONFIG_DIR": str(cfg_dir)})

    def zj(*args: str) -> subprocess.CompletedProcess[str]:
        return subprocess.run(
            ["zellij", "--session", sess, *args],
            check=False,
            capture_output=True,
            text=True,
            env=env,
        )

    client: PTYController | None = None
    try:
        client = PTYController(
            ["zellij", "--config", str(cfg_kdl), "--session", sess],
            env=env,
            cwd=str(ws_dir),
            verbose=verbose,
        )

        # Wait for session responsiveness & Tab 1 terminal pane
        panes: list[dict] = []
        deadline = time.monotonic() + 10.0
        while time.monotonic() < deadline:
            client.drain(0.08)
            r = zj("action", "list-panes", "--all", "--json")
            if r.returncode == 0 and r.stdout.strip().startswith("["):
                data = json.loads(r.stdout)
                non_plugins = [p for p in data if not p["is_plugin"]]
                if non_plugins:
                    panes = non_plugins
                    break
            time.sleep(0.15)
        assert panes, "Timed out waiting for Zellij session"
        t1_pane = f"terminal_{panes[0]['id']}"

        # Create Tab 2 in other_dir
        assert (
            zj(
                "action", "new-tab", "--name", "OtherTab", "--cwd", str(other_dir)
            ).returncode
            == 0
        )
        time.sleep(0.4)
        client.drain(0.05)
        panes2 = json.loads(zj("action", "list-panes", "--all", "--json").stdout)
        t2_list = [
            p for p in panes2 if not p["is_plugin"] and p.get("tab_name") == "OtherTab"
        ]
        assert t2_list, f"OtherTab pane not created: {panes2}"
        t2_pane = f"terminal_{t2_list[0]['id']}"

        # Set clean prompt with ignoreeof in both tabs & emit log line in Tab 2
        for pid in (t1_pane, t2_pane):
            zj(
                "action",
                "paste",
                "--pane-id",
                pid,
                "--",
                "set -o ignoreeof; PS1='READY> '",
            )
            zj("action", "send-keys", "--pane-id", pid, "Enter")
        wait_for_condition(
            lambda: (
                "READY>"
                in zj("action", "dump-screen", "--pane-id", t2_pane, "--full").stdout
            ),
            desc="Zellij Tab 2 prompt",
        )
        zj(
            "action",
            "paste",
            "--pane-id",
            t2_pane,
            "--",
            "printf '\\033[31mTAB2_ZELLIJ_ERR_77\\033[0m\\n'",
        )
        zj("action", "send-keys", "--pane-id", t2_pane, "Enter")
        wait_for_condition(
            lambda: (
                "TAB2_ZELLIJ_ERR_77"
                in zj("action", "dump-screen", "--pane-id", t2_pane, "--full").stdout
            ),
            desc="Zellij Tab 2 log line",
        )

        # Return focus to Tab 1 so Tab 1 is active when floating prompter opens
        zj("action", "go-to-tab", "1")
        time.sleep(0.3)
        client.drain(0.05)

        def launch_floating_prompter(extra_env: str = "") -> Path:
            done_flag = tmp / f"done_{time.monotonic_ns()}.flag"
            zj(
                "run",
                "--floating",
                "--close-on-exit",
                "--",
                "bash",
                "-c",
                f"{extra_env} HERDR_PLUGIN_CONFIG_DIR='{cfg_dir}' bash '{PROMPTER_SCRIPT}'; echo $? > '{done_flag}'",
            )
            return done_flag

        def case_01_active_tab_and_cwd() -> None:
            # Verify --preview-only inside floating pane resolves Tab 1 cwd (git repo) and branch
            out_file = tmp / "zj_preview.txt"
            zj(
                "run",
                "--floating",
                "--close-on-exit",
                "--",
                "bash",
                "-c",
                f"HERDR_PLUGIN_CONFIG_DIR='{cfg_dir}' bash '{PROMPTER_SCRIPT}' --preview-only 'E2E Git Context' > '{out_file}'",
            )
            wait_for_condition(
                lambda: out_file.exists() and out_file.stat().st_size > 0,
                desc="zj preview output",
            )
            text = out_file.read_text(encoding="utf-8")
            assert "BR=feat/e2e-check" in text, text
            assert "UNSTAGED_E2E_LINE" in text, text

        def case_02_floating_cross_tab_choose() -> None:
            # Capture Tab 1 (caller pane) payload cleanly with non-canonical cat
            t1_out = tmp / "zj_t1_cap.txt"
            zj(
                "action",
                "paste",
                "--pane-id",
                t1_pane,
                "--",
                f"stty -echo -icanon min 1 time 0; cat > '{t1_out}'; stty sane",
            )
            zj("action", "send-keys", "--pane-id", t1_pane, "Enter")
            time.sleep(0.25)

            m = client.mark()
            done_flag = launch_floating_prompter()
            m = client.fzf_pick(
                "E2E Cross Pane Logs", header_wait="Templates>", since=m
            )
            client.fzf_pick(
                "OtherTab", header_wait="Select a pane to import logs from:", since=m
            )

            wait_for_condition(
                lambda: done_flag.exists(), timeout=10.0, desc="zj floating exit"
            )
            wait_for_condition(
                lambda: t1_out.exists() and t1_out.stat().st_size > 0,
                desc="zj tab1 paste",
            )
            time.sleep(0.25)
            zj("action", "send-keys", "--pane-id", t1_pane, "Ctrl c")
            wait_for_condition(
                lambda: (
                    "READY>"
                    in (
                        [
                            ln
                            for ln in zj(
                                "action", "dump-screen", "--pane-id", t1_pane, "--full"
                            ).stdout.splitlines()
                            if ln.strip()
                        ]
                        or [""]
                    )[-1]
                ),
                desc="Tab 1 shell restored",
            )
            captured = t1_out.read_text(encoding="utf-8", errors="replace")
            assert "-imported-logs:" in captured, captured
            assert "TAB2_ZELLIJ_ERR_77" in captured, captured
            assert "\x1b[" not in captured, captured

        def case_03_cross_tab_broadcast_and_run_command() -> None:
            b1_out = tmp / "zj_b1.txt"
            b2_out = tmp / "zj_b2.txt"
            for pid, out_p in ((t1_pane, b1_out), (t2_pane, b2_out)):
                zj(
                    "action",
                    "paste",
                    "--pane-id",
                    pid,
                    "--",
                    f"stty -echo -icanon min 1 time 0; cat > '{out_p}'; stty sane",
                )
                zj("action", "send-keys", "--pane-id", pid, "Enter")
            time.sleep(0.3)

            m = client.mark()
            done_flag = launch_floating_prompter("MUX_BACKEND=zellij ")
            m = client.fzf_pick(
                "E2E Broadcast Panes", header_wait="Templates>", since=m
            )
            client.wait_for("Select target panes for broadcast", since=m, settle=0.15)
            client.wait_for("OtherTab", since=m, settle=0.1)
            client.send("\t", delay_after=0.12)
            client.send("\t", delay_after=0.12)
            client.send("\r", delay_after=0.15)
            wait_for_condition(
                lambda: done_flag.exists(),
                timeout=10.0,
                desc="zj broadcast floating exit",
            )

            for pid, out_p in ((t1_pane, b1_out), (t2_pane, b2_out)):
                wait_for_condition(
                    lambda p=out_p: p.exists() and p.stat().st_size > 0,
                    desc=f"broadcast {out_p.name}",
                )
                time.sleep(0.25)
                zj("action", "send-keys", "--pane-id", pid, "Ctrl c")
            time.sleep(0.3)
            assert "-broadcast-msg" in b1_out.read_text(encoding="utf-8")
            assert "-broadcast-msg" in b2_out.read_text(encoding="utf-8")

            # Also verify mux_run_command end-to-end executes command in Tab 2
            r = subprocess.run(
                [
                    "bash",
                    "-c",
                    (
                        f"eval \"$(sed '/^# Main selection and execution loop/,$d' '{PROMPTER_SCRIPT}')\"\n"
                        f"mux_run_command '{t2_pane}' 'echo ZJ_RUN_CMD_OK'\n"
                    ),
                ],
                check=False,
                env={**env, "ZELLIJ_SESSION_NAME": sess, "MUX_BACKEND": "zellij"},
                capture_output=True,
                text=True,
            )
            assert r.returncode == 0, r.stderr
            wait_for_condition(
                lambda: (
                    "ZJ_RUN_CMD_OK"
                    in zj(
                        "action", "dump-screen", "--pane-id", t2_pane, "--full"
                    ).stdout
                ),
                desc="mux_run_command executed in Tab 2",
            )

        def case_04_esc_cancel() -> None:
            before = zj("action", "dump-screen", "--pane-id", t1_pane, "--full").stdout
            m = client.mark()
            done_flag = launch_floating_prompter()
            client.wait_for("Templates>", since=m, settle=0.15)
            client.send("\x1b", delay_after=0.15)
            wait_for_condition(
                lambda: done_flag.exists(), timeout=8.0, desc="zj esc exit"
            )
            assert done_flag.read_text(encoding="utf-8").strip() == "0"
            after = zj("action", "dump-screen", "--pane-id", t1_pane, "--full").stdout
            assert before == after, "Esc cancel modified target pane"

        for name, fn in (
            (
                "ZELLIJ-E2E-01 (Floating active-tab caller pane & cwd resolution)",
                case_01_active_tab_and_cwd,
            ),
            (
                "ZELLIJ-E2E-02 (Real fzf cross-tab dump-screen & paste --)",
                case_02_floating_cross_tab_choose,
            ),
            (
                "ZELLIJ-E2E-03 (Real fzf -m broadcast & mux_run_command)",
                case_03_cross_tab_broadcast_and_run_command,
            ),
            (
                "ZELLIJ-E2E-04 (Floating Esc cancel leaves target untouched)",
                case_04_esc_cancel,
            ),
        ):
            stats.run_case(name, fn)
    finally:
        if client is not None:
            client.close()
        subprocess.run(
            ["zellij", "delete-session", "--force", sess],
            check=False,
            capture_output=True,
            env=env,
        )
        shutil.rmtree(tmp, ignore_errors=True)


# ---------------------------------------------------------------------------
# Herdr E2E Suite
# ---------------------------------------------------------------------------


def run_herdr_e2e(stats: RunnerStats, verbose: bool) -> None:
    if not shutil.which("herdr"):
        stats.record("SKIP", "HERDR-E2E", "herdr binary not found")
        return

    # Use /tmp with a short prefix to stay well under macOS 104-byte sun_path limit for herdr.sock
    tmp = Path(tempfile.mkdtemp(prefix="hd_", dir="/tmp"))
    fake_home = tmp
    ws_dir = tmp / "ws"
    other_dir = tmp / "other"
    cfg_dir = tmp / "cfg"
    (fake_home / ".config").mkdir(parents=True, exist_ok=True)
    other_dir.mkdir(parents=True, exist_ok=True)
    setup_git_workspace(ws_dir)
    setup_templates(cfg_dir)

    env = clean_env(
        {
            "HOME": str(fake_home),
            "XDG_CONFIG_HOME": str(fake_home / ".config"),
            "HERDR_PLUGIN_CONFIG_DIR": str(cfg_dir),
        }
    )

    # Hard isolation guard: never connect to a live Herdr host socket/session
    for forbidden in (
        "HERDR_SOCKET_PATH",
        "HERDR_SESSION",
        "HERDR_CONFIG_PATH",
        "HERDR_ENV",
    ):
        assert forbidden not in env, f"Unsafe inherited env var {forbidden}"

    def hd(*args: str, check: bool = True) -> subprocess.CompletedProcess[str]:
        res = subprocess.run(
            ["herdr", *args],
            check=False,
            capture_output=True,
            text=True,
            env=env,
        )
        if check and res.returncode != 0:
            raise RuntimeError(
                f"herdr {' '.join(args)} failed (rc={res.returncode}): "
                f"stderr={res.stderr.strip()!r} stdout={res.stdout.strip()!r}"
            )
        return res

    sess_chk = hd("session", "list")
    assert str(fake_home) in sess_chk.stdout and "vscode" not in sess_chk.stdout, (
        f"Herdr session isolation check failed:\n{sess_chk.stdout}"
    )

    srv = subprocess.Popen(
        ["herdr", "server"],
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        text=True,
        env=env,
        cwd=str(ws_dir),
        start_new_session=True,
    )

    try:
        # Wait for isolated server socket readiness
        deadline = time.monotonic() + 10.0
        ready = False
        while time.monotonic() < deadline:
            r = hd("pane", "list", check=False)
            if r.returncode == 0:
                ready = True
                break
            if srv.poll() is not None:
                raise AssertionError(
                    f"herdr server exited prematurely: {srv.stderr.read()}"
                )
            time.sleep(0.15)
        assert ready, "Timed out waiting for isolated herdr server"

        panes_data = (
            json.loads(hd("pane", "list").stdout).get("result", {}).get("panes", [])
        )
        if not panes_data:
            ws_res = json.loads(
                hd(
                    "workspace", "create", "--cwd", str(ws_dir), "--label", "E2EWS"
                ).stdout
            )
            _ = ws_res
            panes_data = json.loads(hd("pane", "list").stdout)["result"]["panes"]

        p0 = panes_data[0]["pane_id"]
        split_res = json.loads(
            hd(
                "pane",
                "split",
                p0,
                "--direction",
                "right",
                "--cwd",
                str(other_dir),
                "--no-focus",
            ).stdout
        )
        p1 = split_res["result"]["pane"]["pane_id"]

        # Wait for shell prompt with ignoreeof inside both panes and emit colored log in p1
        time.sleep(0.35)
        for pid in (p0, p1):
            hd("pane", "run", pid, "set -o ignoreeof; PS1='READY> '")
            wait_for_condition(
                lambda id_=pid: (
                    "READY>"
                    in hd("pane", "read", id_, "--lines", "20", check=False).stdout
                ),
                desc=f"Herdr pane {pid} prompt",
            )

        hd("pane", "run", p1, "printf '\\033[31mHERDR_PANE2_ERR_88\\033[0m\\n'")
        wait_for_condition(
            lambda: (
                "HERDR_PANE2_ERR_88"
                in hd("pane", "read", p1, "--lines", "30", check=False).stdout
            ),
            desc="Herdr p1 error log",
        )

        ctx_json = json.dumps(
            {
                "focused_pane_id": p0,
                "workspace_cwd": str(ws_dir),
                "selected_text": "HERDR_SELECTED_SNIPPET",
            }
        )

        def case_01_logs_git_and_choose() -> None:
            out_p0 = tmp / "hd_p0_cap.txt"
            hd(
                "pane",
                "run",
                p0,
                f"stty -echo -icanon min 1 time 0; cat > '{out_p0}'; stty sane",
            )
            time.sleep(0.25)

            p = PTYController(
                ["bash", str(PROMPTER_SCRIPT)],
                env={
                    **env,
                    "HERDR_PLUGIN_CONTEXT_JSON": ctx_json,
                    "MUX_BACKEND": "herdr",
                },
                cwd=str(ws_dir),
                verbose=verbose,
            )
            try:
                m = p.fzf_pick("E2E Cross Pane Logs", header_wait="Templates>", since=0)
                p.fzf_pick(
                    p1, header_wait="Select a pane to import logs from:", since=m
                )
                assert p.wait_exit(timeout=8.0) == 0
            finally:
                p.close()

            wait_for_condition(
                lambda: out_p0.exists() and out_p0.stat().st_size > 0,
                desc="Herdr p0 cat capture",
            )
            time.sleep(0.25)
            hd("pane", "send-keys", p0, "ctrl+c")
            wait_for_condition(
                lambda: (
                    "READY>"
                    in (
                        [
                            ln
                            for ln in hd(
                                "pane", "read", p0, "--lines", "20", check=False
                            ).stdout.splitlines()
                            if ln.strip()
                        ]
                        or [""]
                    )[-1]
                ),
                desc="Herdr p0 shell prompt return",
            )
            captured = out_p0.read_text(encoding="utf-8", errors="replace")
            assert "-imported-logs:" in captured, captured
            assert "HERDR_PANE2_ERR_88" in captured, captured
            assert "\x1b[" not in captured, captured

        def case_02_broadcast() -> None:
            out0 = tmp / "hd_b0.txt"
            out1 = tmp / "hd_b1.txt"
            for pid, op in ((p0, out0), (p1, out1)):
                hd(
                    "pane",
                    "run",
                    pid,
                    f"stty -echo -icanon min 1 time 0; cat > '{op}'; stty sane",
                )
            time.sleep(0.3)

            p = PTYController(
                ["bash", str(PROMPTER_SCRIPT)],
                env={**env, "HERDR_PLUGIN_CONTEXT_JSON": ctx_json},
                cwd=str(ws_dir),
                verbose=verbose,
            )
            try:
                m = p.fzf_pick("E2E Broadcast Panes", header_wait="Templates>", since=0)
                p.wait_for("Select target panes for broadcast", since=m, settle=0.15)
                p.wait_for(p1, since=m, settle=0.1)
                p.send("\t", delay_after=0.12)
                p.send("\t", delay_after=0.12)
                p.send("\r", delay_after=0.15)
                assert p.wait_exit(timeout=8.0) == 0
            finally:
                p.close()

            for pid, op in ((p0, out0), (p1, out1)):
                wait_for_condition(
                    lambda file_p=op: file_p.exists() and file_p.stat().st_size > 0,
                    desc=f"Herdr {op.name}",
                )
                time.sleep(0.25)
                hd("pane", "send-keys", pid, "ctrl+c")
            time.sleep(0.3)
            assert "-broadcast-msg" in out0.read_text(encoding="utf-8")
            assert "-broadcast-msg" in out1.read_text(encoding="utf-8")

        stats.run_case(
            "HERDR-E2E-01 (Isolated server, real fzf, cross-pane read & send-text)",
            case_01_logs_git_and_choose,
        )
        stats.run_case(
            "HERDR-E2E-02 (Herdr auto-detect & multi-pane broadcast)", case_02_broadcast
        )
    finally:
        # Terminate only our isolated server process group; never invoke global `herdr server stop`
        try:
            os.killpg(srv.pid, signal.SIGTERM)
            srv.wait(timeout=3.0)
        except (subprocess.SubprocessError, OSError):
            with suppress(OSError):
                os.killpg(srv.pid, signal.SIGKILL)
        shutil.rmtree(tmp, ignore_errors=True)


def main() -> int:
    parser = argparse.ArgumentParser(
        description="Run mux-prompter real multiplexer E2E tests."
    )
    parser.add_argument(
        "--backend",
        choices=("all", "tmux", "zellij", "herdr"),
        default="all",
        help="Target multiplexer backend suite to execute.",
    )
    parser.add_argument(
        "--verbose", action="store_true", help="Stream stripped PTY output to stderr."
    )
    args = parser.parse_args()

    for req in ("fzf", "jq", "git", "bash"):
        if not shutil.which(req):
            print(f"Missing required dependency: {req}", file=sys.stderr)
            return 1

    stats = RunnerStats()
    for bname, runner in (
        ("tmux", run_tmux_e2e),
        ("zellij", run_zellij_e2e),
        ("herdr", run_herdr_e2e),
    ):
        if args.backend in ("all", bname):
            try:
                runner(stats, args.verbose)
            except Exception as exc:  # noqa: BLE001
                stats.record("FAIL", f"{bname.upper()}-E2E-SETUP", str(exc))

    return stats.summary()


if __name__ == "__main__":
    sys.exit(main())

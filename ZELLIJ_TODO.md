# Zellij Support Roadmap & Technical Notes (TODO)

## 📌 Context
Zellij support in `mux-prompter` is currently paused. Basic single-pane prompt picking and floating UI work, but multi-pane targeting (`{{pane:choose}}` / `{{panes:choose}}`) could not be reliably achieved during integration testing.

---

## 📊 Fact vs. Hypothesis Analysis

### 1. 【確定事実】実機テストで確認された動作 (Verified Facts from Testing)
- **Floating UI の正常動作**: Zellij 上で `Run "/path/to/prompter.sh" { floating true }` を実行すると、中央に 80%×60% の `fzf` ポップアップが正常に起動する。
- **ペイン ID 認識の事実**: `zellij action list-panes -j` で取得したペイン ID（例: `0` や `21`）をユーザーが選択しても、最終的な文字注入（`write-chars`）は常に同じ画面（`Pane 0`）に届く。
- **誤消去の事実**: スクリプト終了時に `zellij action close-pane` を呼び出すと、フォーカスが移動していた場合にユーザーのメイン作業ペイン自体が閉じてしまう。

### 2. 【公式仕様】Zellij ドキュメント・CLI ヘルプに明記されている仕様 (Official Specs)
- **`--pane-id` オプション**: `zellij action write-chars --pane-id <PANE_ID>` および `dump-screen --pane-id <PANE_ID>` は、特定のペインをターゲット指定するための公式 CLI 引数である（`zellij action --help` に明記）。
- **`--session` オプション**: 外部プロセスやサブシェルから `zellij action` を実行する場合、`zellij --session <SESSION_NAME> action ...` と明示しないとアクティブセッションの特定に失敗する（公式ドキュメント `zellij.dev` に明記）。
- **`write-chars` vs `paste`**: マルチラインや信頼性の高い文字送信には `write-chars` よりも `zellij action paste` が推奨されている（公式ドキュメント `zellij.dev` に明記）。

### 3. 【仮説・未検証の推測】AI による推論（Unverified Hypotheses）
> ⚠️ **以下は公式ドキュメントに明記されておらず、検証が不十分な AI の推測・仮説です。**
- **推測 A**: 「Floating ウィンドウが起動している間、Zellij 内部でフォーカスが物理的にロックされ、`--pane-id` による背景ペインへの文字注入コマンドが無視されてデフォルトペイン（`Pane 0`）にフォールバックしている可能性がある。」
- **推測 B**: 「Zellij CLI の `--pane-id` フラグ自体に、特定のペイン ID（数値や `terminal_<ID>`）を受け付けず現在フォーカス位置へ送信してしまうバージョン固有のバグが存在する可能性がある。」

---

## 💡 Proposed Future Roadmap

### Phase 1: シングルペイン専用 MVP モード（安全な機能制限リリース）
- 標準テンプレート（`{{git_diff}}`, `{{selected}}`, `{{var}}` 等）のみを Zellij 対応対象とする。
- `{{pane:choose}}` / `{{panes:choose}}` が含まれるテンプレート実行時のみ、「Zellij では他ペイン選択は未対応です」と警告を表示し、安全に現在のアクティブペインにのみ送信する。

### Phase 2: マルチペイン対応の再検証（上流調査 / WASM プラグイン）
- `zellij-org/zellij` の GitHub Issue で CLI の `--pane-id` 挙動に関する修正を継続追跡する。
- TUI シェルスクリプト経由ではなく、Zellij 公式の WASM プラグイン API（Rust `.wasm`）を利用して直接ペイン制御を行うアプローチを検討する。


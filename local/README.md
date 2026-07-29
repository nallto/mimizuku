# local/ — 個人用ローカル領域(README 以外は追跡しない)

このフォルダは、開発者がこのプロジェクトに関する個人的なファイルを置く場所です。`.gitignore` により、この README 以外の中身はコミットされません(`/local/*` を無視し、`local/README.md` だけ追跡)。

用途の例:

- 実験用スクリプト・下書き・スクラッチ
- ローカル検証の録音・ログ・スクリーンショット(※ 音声・文字起こしそのものはコミット禁止)
- プロジェクト個人メモ
- `worktrees/`: Agentや開発者が明示的に作るGit worktree
- `agent-artifacts/`: PR本文、承認snapshot、検証結果など、セッションやコマンドを越えて参照するAgent作業ファイル
- `cache/`: 再取得・再生成できるプロジェクト固有のキャッシュ

使い分け:

- `CLAUDE.local.md`(リポジトリ直下、gitignore 済み)= AI 向けの個人メモ。Claude Code が読む慣例の場所。
- `local/`(このフォルダ)= それ以外の個人ファイル全般。

終了時に必ず削除するテストfixtureは`mktemp`、OS・Swift・Xcode・Agent製品自身が管理する内部データは各製品の一時領域を利用して構いません。Agentが作るプロジェクト固有ファイルを、後のターンやセッションでも参照する場合は`local/`へ置きます。

チームや他の開発者・AI も知るべき内容は、ここに置かず AGENTS.md / docs/ / ADR / GitHub Issues へ昇華させてください。

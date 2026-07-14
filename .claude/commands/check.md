--- description: CI と同等の検証(just check)を実行し、結果を報告するallowed-tools: Bash(just check), Bash(just --list) ---

`just check` を実行し、結果を報告してください。

- green の場合: 「検証 green」と各項目の結果を簡潔に報告する。
- red の場合: 失敗した項目・原因の仮説・修正方針を報告する。勝手に修正へ着手せず、方針の承認を先に得ること。

注意: `just check` は純ロジックのパッケージテストのみ。マイク / システム音声 / TCC の挙動はここでは検証されず、人間がローカル実機で検証する必要がある。

# 開発への参加

1. 規約の正典は [AGENTS.md](./AGENTS.md)。作業前に必ず読む(AI エージェントも同じものを読んでいる)。ドメイン上の罠は [docs/domain-pitfalls.md](./docs/domain-pitfalls.md)。
2. セットアップと強制装置の全体像は [docs/development.md](./docs/development.md)。

```bash
mise install   # ツール一式(版数は mise.toml が SSOT)
just check     # CI と同一の検証
```

3. 変更フロー: Issue 起票 → `<type>/<issue番号>-<説明>` ブランチ → PR(squash マージ)。PR タイトルは Conventional Commits 準拠(CI が検証)。
4. コントリビューションは inbound=outbound モデル + DCO サインオフ(`git commit -s`)で受け付けます。CLA はありません。(ライセンス確定は保留中 ―― docs/adr/0002 と LICENSE-TODO.md を参照。)
5. 注意: macOS 26 / Apple Silicon 限定。音声・TCC の挙動は CI でテストできません。捕捉・文字起こしの変更は、該当スライスの手動ローカルテストを実行してから「動く」と主張してください。

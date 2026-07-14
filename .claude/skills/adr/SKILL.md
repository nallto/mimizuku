--- name: adr description: 設計判断を ADR(Architecture Decision Record)として記録する手順。MADR 形式。設計判断、アーキテクチャ決定、技術選定、規約変更を記録するときに使用する。---

# ADR 起票手順

1. その判断が「後から参加する人(や AI)が『なぜこうなっている?』と問うもの」か確認する。該当しなければ ADR は不要(コミットメッセージや docs で足りる)。
2. 種別を選ぶ:
   - **製品 / アーキテクチャ**判断 → `docs/adr/NNNN-短いタイトル.md`(このフォルダ内の次の連番)。
   - **プロセス / 統治**判断 → `docs/adr/governance/G-NNNN-短いタイトル.md`。`docs/adr/template.md` をコピーして起点にする。
3. 以下を埋める:
   - Context: 課題・制約。検討した代替案と却下理由もここに含める。
   - Decision: 採用する方針(具体的に)。
   - Consequences: 得るもの・失うもの(トレードオフ)・今後の影響。
4. ステータスは `Proposed` で起票し、承認を得てから `Accepted` にする。
5. 既存の ADR を覆す場合は書き換えず、新しい ADR を作成して旧 ADR のステータスに`Superseded by ADR-NNNN` を記す(判断の履歴を残すため)。
6. 対応する種別の `docs/adr/README.md` の一覧表に行を追加する。
7. 原則、実装 PR より先に(または同じ PR で)ADR を入れる。

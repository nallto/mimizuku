---
name: agent-config
description: Agent用skill、subagent、command、hook、権限、接続設定を追加・変更・削除するときに、対応する全Agentへの影響を確認して多重管理を防ぐ手順。
---

# Agent設定変更の横断確認

`.agents/`、`.claude/`、`.codex/`、`scripts/agent-hooks/`、またはAgentの動作を変える規約・設定に触れる前に、この手順を使う。

## 1. 対応範囲を確定する

1. `.agents/integrations.json`を読み、正式に接続しているAgentとfallbackを列挙する。
2. 変更対象を次のいずれかに分類する。
   - **共通の意味・手順**: `.agents/skills/`、`AGENTS.md`、`docs/`
   - **共通の決定的処理**: `scripts/agent-hooks/`、共通検証script
   - **製品別アダプター**: `.claude/`、`.codex/`などの探索・イベント接続
   - **製品固有機能**: 他製品へ同等機能がなく共通化できない設定
3. 共通化できる本文や判定を製品別設定へ複製しない。製品別ファイルには探索、接続、権限、利用可能toolなど、その製品にしか表現できない内容だけを置く。

## 2. 影響表を作る

計画に次の表を含め、registryにある全Agentを1行ずつ確認する。

| Agent / fallback | 影響 | 必要な変更 | 機械検証 | 製品上の手動確認 |
| --- | --- | --- | --- | --- |
| `<id>` | あり / なし | 対象ファイル、または非対応理由 | コマンド | 新規sessionでの探索・hook確認 |

「影響なし」は理由を書く。未知の設定schemaや最近変わりうる製品仕様を推測せず、公式資料または対象製品の実動作で確認する。

## 3. 変更種別ごとの確認

### 共通skill

- `SKILL.md`のfrontmatterを有効なYAMLにし、`name`と具体的な`description`を持たせる。
- 新しい共通skillには、registryで`adapter`とされた全Agentの同名アダプターを追加する。
- アダプターは共通`SKILL.md`を完全に読む指示だけにし、手順本文を複製しない。
- commandとskillが同名・同目的なら、製品の優先順位を確認して一方へ統合する。

### hook・権限・subagent

- 入力schemaと失敗時の意味が同じ処理だけを共通scriptへ移す。
- 共通scriptには許可ケースと拒否ケースの実効テストを追加する。
- 製品別設定は共通scriptや検証基準への参照に留める。
- trust、sandbox、権限、イベント差によって同じ保証ができない場合は、非対応理由と代替する最終保証をdocsへ記録する。
- ローカル個人設定や秘密情報を共通設定へ移さない。

### 新しいAgent製品

- `.agents/integrations.json`へ探索方式と接続設定を登録する。
- native探索、adapter、AGENTS.md経由のfallbackのどれを使うか明示する。
- adapterが必要なら、既存の全共通skillへの入口を同時に追加する。
- 公式の新規sessionでskill探索とhook動作を確認する。

## 4. 検証と記録

1. `just agent-config-check`でregistry、YAML、双方向adapter、hook参照を検証する。
2. `just check`をgreenにする。
3. 非自明な変更は独立verifierを通す。
4. 製品上でしか確認できない探索・trust・hook発火は新規sessionで手動確認し、結果または未確認理由をPR本文へ記録する。
5. 配置や責務の判断を変える場合は、既存ADRを書き換えず新しいgovernance ADRを起票する。

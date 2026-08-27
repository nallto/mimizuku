# G-0011: release-please PRのマージ実行は人間に限定する

- ステータス: Accepted
- 日付: 2026-08-27
- 関連: #135, #131, G-0002, G-0006, G-0008, G-0010

## Context(背景)

G-0002は、release-pleaseが生成するリリースPRをマージした瞬間だけタグ、GitHub Release、CHANGELOG更新を発生させ、リリース判断を1か所へ集約している。通常PRは、利用者が対象と状態を確認して明示承認した後ならAI Agentがマージを実行できるが、リリースPRのマージは製品を外部へ公開する操作そのものであり、承認後の実行もAIへ委ねず人間自身が行う境界にする必要がある。

この境界は、承認者が応答できるかというG-0010の「無人実行」や、GitHub GUIとCLIのどちらを使うかでは決まらない。判定軸は、操作者がAI Agentか人間か、対象がrelease-please管理のPRかどうかである。同じGitHubアカウントを人間とAgentが使う構成ではGitHub側が操作経路を区別できないため、Agent製品が共有するPreToolUse hookとリポジトリ所有のマージ入口で防誤操作を強制する。

検討した代替案:

- **すべてのPRを人間だけがマージする(却下)**: 通常PRでは、対象と状態を示した明示承認後にAgentが定型的なsquash mergeを実行できる既存フローを維持したい。リリースPR固有の外部公開リスクに対して範囲が広すぎる。
- **無人実行時だけ拒否する(却下)**: リリースPRは有人セッションでもAgentへ実行を委ねない。無人状態を機械的に識別する新たな契約も不要である。
- **GitHub GUIだけを許可する(却下)**: 人間自身のCLI操作まで制限する理由がなく、同一権限主体のGUIとCLIをGitHubのブランチ保護で区別することもできない。
- **直接の`gh pr merge`で毎回PRを照会する(却下)**: 共通hookをネットワーク依存にすると、timeoutがfail-openになるAgent surfaceで保証が弱くなる。決定的なhookは直接経路を拒否し、ネットワークを使う対象判定は専用スクリプトへ分離する。
- **Agent用の専用マージ入口を設ける(採用)**: 通常PRのマージ能力を維持したまま、release-please管理ブランチだけを対象情報に基づいて拒否できる。

## Decision(決定)

1. release-please管理PRのマージ実行は人間だけが行う。明示承認済みでもAI Agentは実行しない。人間が使う操作経路はGUI・CLIを問わない。
2. release-please管理PRは、headブランチ名が`release-please--branches--*`に一致するPRと定義する。タイトルや作成者は将来の設定・認証方式で変わりうるため主判定に使わない。
3. AI Agentによる通常PRのマージは、リポジトリ所有の専用スクリプトを唯一の入口にする。専用スクリプトは対象PRのheadブランチをGitHubから取得し、決定2に一致すればマージ前に拒否し、それ以外は既存の承認snapshot、全check確認、`--match-head-commit`を使う手順を維持してマージする。
4. 共通PreToolUse hookは、Agentからの直接の`gh pr merge`、REST APIのPR merge endpoint、GraphQLのmerge・auto-merge・merge queue操作を拒否し、専用スクリプトへ誘導する。hookはローカルのコマンド判定だけを行い、GitHubへの問い合わせを行わない。
5. この仕組みは、正式対応Agentが通常利用する既知のGitHub CLI経路での防誤操作を目的とする。独自HTTPクライアント、動的に構築されたリクエスト、hook未接続のfallbackまで封じるセキュリティ境界とは扱わない。

## Consequences(結果)

- 得るもの:
  - release-please PRは、有人・無人を問わずAgentの正式なマージ経路から拒否される。
  - 通常PRは、利用者の明示承認後にAgentがマージする既存フローを維持できる。
  - 共通hookはネットワーク非依存の決定的処理を保ち、全正式対応Agentへ同じ判定を配布できる。
- 失うもの:
  - Agentは通常PRでも`gh pr merge`を直接使えず、専用スクリプトを経由する必要がある。
  - GitHub CLIに新しいマージ経路が追加された場合は、共通hookの拒否対象を更新する必要がある。
  - hook未接続のfallbackと意図的な迂回は機械的に拒否できず、G-0008の規律が最終保証になる。
- 維持する保証:
  - マージ前の対象snapshot、全check、明示承認、`--match-head-commit`、squash本文の手順は変更しない。
  - release-pleaseはリリースPRの作成・更新を担い、リリース自体はそのPRを人間がマージしたときだけ発生する。

// investigate-issues共通skillのClaude Code用オーケストレーション(G-0010 決定1・2)。
// 手順・出力形式・上限の正典は .agents/skills/investigate-issues/SKILL.md。
// このスクリプトは並列化の機構だけを担い、調査内容の定義を複製しない。
export const meta = {
  name: 'investigate-issues',
  description: 'Issue番号列を並列調査し、着手判断の比較材料を同一形式で返す',
  phases: [
    { title: 'Investigate', detail: 'Issueごとに読み取り専用の調査を1体ずつ' },
    { title: 'Synthesize', detail: '依存関係を考慮した推奨着手順へ統合' }
  ]
}

// 共通skillの上限: 1起動 = 調査8体 + 統合1体 = 最大9体。
const ISSUE_LIMIT = 8

const ISSUE_SCHEMA = {
  type: 'object',
  required: [
    'number', 'title', 'size', 'sizeRationale', 'dependencies', 'adrNeeded',
    'ciVerifiable', 'deviceOnly', 'prSplit', 'risks'
  ],
  properties: {
    number: { type: 'integer' },
    title: { type: 'string' },
    size: { type: 'string', enum: ['S', 'M', 'L'] },
    sizeRationale: { type: 'string' },
    dependencies: { type: 'array', items: { type: 'string' } },
    adrNeeded: { type: 'boolean' },
    adrTopic: { type: 'string' },
    ciVerifiable: { type: 'string' },
    deviceOnly: { type: 'string' },
    prSplit: { type: 'array', items: { type: 'string' } },
    risks: { type: 'array', items: { type: 'string' } }
  }
}

const SYNTHESIS_SCHEMA = {
  type: 'object',
  required: ['order', 'summary'],
  properties: {
    order: {
      type: 'array',
      items: {
        type: 'object',
        required: ['number', 'reason'],
        properties: {
          number: { type: 'integer' },
          reason: { type: 'string' }
        }
      }
    },
    summary: { type: 'string' },
    conflicts: { type: 'array', items: { type: 'string' } }
  }
}

// argsは配列だけでなく、skillの$ARGUMENTS経由の文字列("112 113"や"[112, 113]")でも
// 渡ってくるため、数値の抽出で受け付ける。
function parseIssueNumbers(input) {
  if (Array.isArray(input)) return input.map(Number)
  if (typeof input === 'number') return [input]
  if (typeof input === 'string') {
    return input.split(/[^0-9]+/).filter(Boolean).map(Number)
  }
  return []
}

// 同じIssueを複数体で調査しないよう、順序を保って重複を除く。
const numbers = [...new Set(
  parseIssueNumbers(args).filter((value) => Number.isInteger(value) && value > 0)
)]
if (numbers.length === 0) {
  throw new Error('Issue番号をargsへ渡す(例: [112, 113, 115] または "112 113 115")')
}
const targets = numbers.slice(0, ISSUE_LIMIT)
const dropped = numbers.slice(ISSUE_LIMIT)
if (dropped.length > 0) {
  // 無言の切り捨てをしない(共通skillの入力規則)。
  log(`上限${ISSUE_LIMIT}件を超えたため調査対象外: #${dropped.join(', #')}`)
}

phase('Investigate')
const investigated = await parallel(targets.map((number) => () =>
  agent(
    [
      `Mimizukuリポジトリの Issue #${number} を、着手判断のために読み取り専用で調査する。`,
      '手順の正典 .agents/skills/investigate-issues/SKILL.md を完全に読み、',
      '「各Issueの調査内容(同一形式)」の7項目に従って評価すること。',
      `Issue本文は \`gh issue view ${number} --comments\` で読む。`,
      '関連ADR・docs/domain-pitfalls.md・言及されているコードも読む。コードは変更しない。',
      '結果はStructuredOutputのschemaに従って返す。根拠には参照したファイルやIssue番号を含める。'
    ].join('\n'),
    { label: `issue-${number}`, phase: 'Investigate', schema: ISSUE_SCHEMA }
  ).then((result) => ({ number, result }))
))
const succeeded = investigated.filter(Boolean).filter((item) => item.result)
const failedNumbers = targets.filter(
  (number) => !succeeded.some((item) => item.number === number)
)
if (failedNumbers.length > 0) {
  // 停止条件: 失敗したIssueは「調査失敗」として結果に含め、再試行しない。
  log(`調査失敗(再試行しない): #${failedNumbers.join(', #')}`)
}

phase('Synthesize')
let synthesis = null
if (succeeded.length > 0) {
  synthesis = await agent(
    [
      '以下は複数Issueの並列調査の結果(JSON)。依存関係を考慮した推奨着手順を作る。',
      '個別調査の内容は書き換えず、矛盾があればconflictsに明記する。',
      '結果はStructuredOutputのschemaに従って返す。',
      '',
      JSON.stringify(succeeded.map((item) => item.result))
    ].join('\n'),
    { label: 'synthesize', phase: 'Synthesize', schema: SYNTHESIS_SCHEMA }
  )
}

return {
  issues: succeeded.map((item) => item.result),
  failedNumbers,
  droppedNumbers: dropped,
  synthesis
}

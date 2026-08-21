// slice-prep共通skillのClaude Code用オーケストレーション(#108、G-0010 決定1・2)。
// 読むソース・出力形式・上限の正典は .agents/skills/slice-prep/SKILL.md。ここへ複製しない。
export const meta = {
  name: 'slice-prep',
  description: 'スライス着手前の正典5ソースを並列に読み、計画草案と未決論点へ統合する',
  phases: [
    { title: 'Read', detail: '正典ソースごとに読み手1体(read-only)' },
    { title: 'Synthesize', detail: '計画草案・未決論点・検証範囲へ統合' }
  ]
}

// 共通skillの上限: 読み手5体 + 統合1体 = 最大6体。
// ソースの名前だけを持つ。読む対象の定義は共通skillの「読むソース」節が正典。
const SOURCES = [
  '実装計画とIssue',
  '関連ADR',
  'デザイン正典',
  'ドメインの罠',
  '既存コード'
]

const READER_SCHEMA = {
  type: 'object',
  required: ['completed', 'facts', 'constraints', 'openQuestions'],
  properties: {
    completed: { type: 'boolean' },
    facts: { type: 'array', items: { type: 'string' } },
    constraints: { type: 'array', items: { type: 'string' } },
    openQuestions: { type: 'array', items: { type: 'string' } },
    notes: { type: 'string' }
  }
}

const SYNTHESIS_SCHEMA = {
  type: 'object',
  required: [
    'planDraft', 'openIssues', 'deviceChecks', 'ciScope', 'prSplit', 'unknowns'
  ],
  properties: {
    planDraft: { type: 'string' },
    openIssues: { type: 'array', items: { type: 'string' } },
    deviceChecks: { type: 'array', items: { type: 'string' } },
    ciScope: { type: 'string' },
    prSplit: { type: 'array', items: { type: 'string' } },
    unknowns: { type: 'array', items: { type: 'string' } }
  }
}

const target = typeof args === 'string' ? args.trim() : args == null ? '' : String(args)
if (!target) {
  throw new Error('スライス番号またはIssue番号をargsへ渡す(例: "S7" または "40")')
}

phase('Read')
const readings = await parallel(SOURCES.map((source, index) => () =>
  agent(
    [
      `Mimizukuリポジトリで、対象「${target}」への着手前の下調べを読み取り専用で行う。`,
      '手順の正典 .agents/skills/slice-prep/SKILL.md を完全に読み、',
      `「読むソース」節のソース「${source}」だけを担当して読む(他ソースの結論を出さない)。`,
      '対象がスライス番号なら docs/plan/IMPLEMENTATION_PLAN.md と対応Issueで範囲を確定する。',
      'ファイルは変更しない。事実・制約・未決論点には根拠(ファイル・ADR・Issue番号)を含める。',
      'ソースを読み切れなかった場合は completed=false とし、理由を notes に書く。'
    ].join('\n'),
    { label: `read:${index + 1}-${source}`, phase: 'Read', schema: READER_SCHEMA }
  ).then((result) => ({ source, result }))
))

// 読み手が値を返したもの(completed=false の部分読了を含む)。
const returnedReadings = readings.filter(Boolean).filter((r) => r.result)
const unreadSources = SOURCES.filter(
  (s) => !returnedReadings.some((r) => r.source === s && r.result.completed)
)
if (unreadSources.length > 0) {
  // 停止条件: 読めなかったソースは再試行せず「未読」として明示する。
  log(`未読ソース(再試行しない): ${unreadSources.join(', ')}`)
}

phase('Synthesize')
// 読み手が全滅した場合は空材料から草案を創作させない(統合をスキップして返す)。
if (returnedReadings.length === 0) {
  log('全ソースの読み込みに失敗したため統合をスキップする')
  return { target, synthesis: null, unreadSources, sourceSummaries: [] }
}
const synthesis = await agent(
  [
    `対象「${target}」の着手前下調べの統合を行う。`,
    '手順の正典 .agents/skills/slice-prep/SKILL.md の「出力形式(統合)」節に従い、',
    '以下の読み込み結果(JSON)を計画草案・未決論点・実機検証項目・CI検証可能範囲・',
    'PR分割案・未読と不確実性へまとめる。読み込み結果に無い事実を創作しない。',
    unreadSources.length > 0
      ? `未読ソースがある: ${unreadSources.join(', ')}。統合結果にその前提を明記する。`
      : '',
    '',
    JSON.stringify({
      readings: returnedReadings.map((r) => ({ source: r.source, ...r.result })),
      unreadSources
    })
  ].join('\n'),
  { label: 'synthesize', phase: 'Synthesize', schema: SYNTHESIS_SCHEMA }
)

return {
  target,
  synthesis,
  unreadSources,
  sourceSummaries: returnedReadings.map((r) => ({
    source: r.source,
    completed: r.result.completed,
    factCount: r.result.facts.length,
    openQuestionCount: r.result.openQuestions.length
  }))
}

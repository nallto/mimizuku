// verify共通skill「観点分割」のClaude Code用オーケストレーション(#107、G-0010 決定1・2)。
// 観点定義・判定規則・上限の正典は .agents/skills/verify/SKILL.md、
// 検証基準の正典は .agents/skills/verify/references/verifier.md。ここへ複製しない。
export const meta = {
  name: 'verify',
  description: '観点別の並列検証と指摘ごとの反証再検証で、生存した指摘だけを報告する',
  phases: [
    { title: 'Review', detail: '5観点の独立レビュー(read-only)' },
    { title: 'Refute', detail: '指摘ごとに反証専任1体(最大10件)' }
  ]
}

// 共通skillの上限: 観点5体 + 再検証最大10体 = 最大15体。
const REFUTE_LIMIT = 10

// 観点の名前だけを持つ。中身の定義は共通skillの「観点分割」節が正典で、
// 各エージェントはそこを読んで担当範囲を決める。
const PERSPECTIVES = [
  '要求とdiffの整合',
  'Swift 6並行性とSendable',
  '失敗系とfail-closed',
  'docs・コード・テストの整合',
  'domain-pitfalls・ハード制約'
]

const FINDINGS_SCHEMA = {
  type: 'object',
  required: ['completed', 'findings', 'summary'],
  properties: {
    completed: { type: 'boolean' },
    findings: {
      type: 'array',
      items: {
        type: 'object',
        required: ['title', 'severity', 'file', 'evidence'],
        properties: {
          title: { type: 'string' },
          severity: { type: 'string', enum: ['blocking', 'minor'] },
          file: { type: 'string' },
          evidence: { type: 'string' }
        }
      }
    },
    summary: { type: 'string' }
  }
}

const REFUTE_SCHEMA = {
  type: 'object',
  required: ['refuted', 'reasoning'],
  properties: {
    refuted: { type: 'boolean' },
    reasoning: { type: 'string' }
  }
}

// argsは {requirements, diffRange} または全文の文字列。
const requirements =
  typeof args === 'string'
    ? args
    : args && typeof args === 'object'
      ? [args.requirements, args.diffRange && `diff範囲: ${args.diffRange}`]
          .filter(Boolean)
          .join('\n')
      : ''
if (!requirements) {
  throw new Error('検証対象の要求とdiff範囲をargsへ渡す(文字列または {requirements, diffRange})')
}

phase('Review')
const reviews = await parallel(PERSPECTIVES.map((perspective, index) => () =>
  agent(
    [
      'あなたは観点分担の独立verifierの1体である。',
      'まず .agents/skills/verify/references/verifier.md を完全に読み、その基準に従う。',
      '次に .agents/skills/verify/SKILL.md の「観点分割」節を読み、',
      `担当観点「${perspective}」だけを深掘りする(他観点の指摘は出さない)。`,
      '機械検証(just check)は呼び出し側で実施済みのため再実行不要。',
      '必要な場合のみ個別のテスト・コマンドを読み取り専用で実行してよい。',
      '',
      '## 検証対象',
      requirements,
      '',
      '指摘は一次情報(ファイル:行、コマンド結果)を evidence に含め、schemaで返す。',
      '観点を最後まで検証しきれなかった場合は completed=false とし、理由を summary に書く。'
    ].join('\n'),
    {
      label: `review:${index + 1}-${perspective}`,
      phase: 'Review',
      schema: FINDINGS_SCHEMA,
      agentType: 'verifier'
    }
  ).then((result) => ({ perspective, result }))
))

const completedReviews = reviews.filter(Boolean).filter((r) => r.result)
const incompletePerspectives = PERSPECTIVES.filter(
  (p) =>
    !completedReviews.some((r) => r.perspective === p && r.result.completed)
)

// 観点間の重複指摘は反証前に機械的に除く(同一ファイル・同一タイトル)。
// 同一キーで severity が割れた場合は blocking を残す(minor 先着で blocking を落とさない)。
const byKey = new Map()
for (const review of completedReviews) {
  for (const finding of review.result.findings) {
    const key = `${finding.file} | ${finding.title}`.toLowerCase()
    const existing = byKey.get(key)
    if (!existing || (existing.severity !== 'blocking' && finding.severity === 'blocking')) {
      byKey.set(key, { ...finding, perspective: review.perspective })
    }
  }
}
const allFindings = [...byKey.values()]

phase('Refute')
// blocking を優先して反証枠(最大10)へ載せ、超過分は未再検証として全件残す。
const ordered = [
  ...allFindings.filter((f) => f.severity === 'blocking'),
  ...allFindings.filter((f) => f.severity !== 'blocking')
]
const toRefute = ordered.slice(0, REFUTE_LIMIT)
const unrefutedOverflow = ordered.slice(REFUTE_LIMIT)
if (unrefutedOverflow.length > 0) {
  log(`指摘${ordered.length}件のうち${unrefutedOverflow.length}件は反証枠(${REFUTE_LIMIT})超過のため未再検証のまま報告する`)
}

const refuted = await parallel(toRefute.map((finding, index) => () =>
  agent(
    [
      'あなたは反証専任の検証者である。以下の指摘を一次情報(コード・diff・テスト・実行結果)で',
      '**潰せるか**を試す。反証できる根拠を見つけたら refuted=true。',
      '指摘が一次情報で裏付けられる場合のみ refuted=false。判断がつかない場合は refuted=true に寄せる',
      '(誤検知を残さないため。.agents/skills/verify/SKILL.md「観点分割」の再検証規則)。',
      '読み取り専用で動作し、ファイルを変更しない。',
      '',
      '## 指摘',
      JSON.stringify(finding)
    ].join('\n'),
    {
      label: `refute:${index + 1}-${finding.file}`,
      phase: 'Refute',
      schema: REFUTE_SCHEMA,
      agentType: 'verifier'
    }
  ).then((verdict) => ({ finding, verdict }))
))

const survivors = []
const killed = []
for (let index = 0; index < toRefute.length; index += 1) {
  const item = refuted[index]
  if (!item || !item.verdict) {
    // 反証エージェントが失敗した指摘は、潰せていないので生存側に残す(安全側)。
    survivors.push({ ...toRefute[index], refutation: '反証エージェント失敗(未反証のため生存)' })
    continue
  }
  if (item.verdict.refuted) {
    killed.push({ ...item.finding, refutation: item.verdict.reasoning })
  } else {
    survivors.push({ ...item.finding, refutation: item.verdict.reasoning })
  }
}

// 判定は機械的に算出する(SKILL.md「観点分割」の判定規則)。
// blockingの生存指摘(未再検証の超過分を含む)があればFAIL。minorだけなら
// PASSとして観察を全件報告する。観点が未完走ならPASSを出さない。
const hasBlocking = [...survivors, ...unrefutedOverflow].some(
  (finding) => finding.severity === 'blocking'
)
const verdict =
  incompletePerspectives.length > 0
    ? 'INCONCLUSIVE'
    : hasBlocking
      ? 'FAIL'
      : 'PASS'

return {
  verdict,
  survivors,
  unrefutedOverflow,
  killed,
  incompletePerspectives,
  perspectiveSummaries: completedReviews.map((r) => ({
    perspective: r.perspective,
    completed: r.result.completed,
    findingCount: r.result.findings.length,
    summary: r.result.summary
  }))
}

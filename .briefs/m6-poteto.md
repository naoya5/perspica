# M6 への追加: poteto mode で進める

ユーザーから「poteto mode で」と指示があった。この依頼の進め方を poteto mode に合わせる。

まず読むもの（すべてファイルを開いて読む）:

- `/Users/naoya/dev/my-bb-plugin/plugins/poteto-mode/pstack/skills/poteto-mode/SKILL.md`
- `playbooks/bug-fix.md`（箇条書きの切れる件はこれ。再現 → 根因 → 修正の順で、実行した証拠を残す）
- `playbooks/hillclimb.md`（速さはこれ。1 つの変更に 1 回の計測。`decision.tsv` に試したこと・前・後・採否を 1 行ずつ残す。場所は `projects/translate-app/.briefs/m6-decision.tsv`、git には入れない）
- `playbooks/perf-issue.md` の 2 の mantra（やらない → もう一度やらない → 回数を減らす → あとでやる → 見えないところでやる → 同時にやる → 安くやる、の順に安いほうから試す）
- 原則のうち **explain-the-number**（数字を報告する前に、何がその数字を決めているか・別のものを測っていないかを確かめる）と **prove-it-works**（実物で確かめるまで「直した」と言わない）は `skills/principle-explain-the-number/SKILL.md` と `skills/principle-prove-it-works/SKILL.md` を読む

あわせること:

- **ユーザーの目的は「F4 と PDF を日常で気持ちよく使える質にする」こと。** 目標の数字はそのための目安。報告の最初の行で、この目的に対して何がどれだけ近づいたかを書く
- 計測の台は一度作ったら固める。受け入れは「ノイズを超えて動き、テストが緑のまま」のときだけ。動かなかった変更は全部戻す
- 報告では、判断に使った原則の名前と、その原則で変えた選択を書く（読んだ原則だけ）
- コミットはしない（親がまとめて行う）。これは poteto mode の PR の手順の代わり

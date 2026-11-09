# translate-app - ローカル翻訳アプリ（仮称 Yaku）

**Created:** 2026-11-06
**Status:** Prototype（M6 完了・レビュー合格。M7 = 設定・管理ウィンドウの UI 改善を実装（[docs/checks/M7.md](docs/checks/M7.md)、221 テスト）。親のレビュー合格（撮影 24 枚、翻訳と履歴の HSplitView のはみ出しを修正）。VoiceOver の実画面比較だけ未実施。残りは利用者の手の確認: manual.md の A2/A5/A7 やり直しと B。A2/A7 のホットキーは SkillHub などとの衝突の疑い）

## What We're Building

PLaMo 3 Translate を Mac の中だけで動かし、選んだ文・入力した文・PDF・画面の文字を訳すメニューバー常駐アプリ。SwiftUI + Liquid Glass。仕様は [SPEC.md](SPEC.md)。

## Current Phase

M0・M1 完了（`docs/checks/M0.md`・`M1.md`）。M1 の ⌃⌥J の実地確認は、アクセシビリティの許可を与えてから人が行う → M2 完了（見た目と CPU は画面ロックのため未確認。ロック解除後に親が撮る）→ M3 完了（15 ページ 92.9 秒。見た目は未確認）→ M4 完了（画面の翻訳。最初のブロック 0.41〜0.69 秒。見た目は未確認）。

2026-11-07 夜: ロックが解け、M2〜M4 の撮影 84 枚と計測を済ませた（各 M*.md の 7 章）。撮影で見つかった不具合（重ね表示の文字が 3 倍の大きさ、デモの位置のずれ、短い英文の言語判定、途中で終わった PDF が「処理中」のまま、文言 3 か所）は直してインストール済み（158 テスト）。撮影の手順書は本物のデータを使っていたので、既定を一時のフォルダに変えた。

2026-11-08: M5 を受け取った（[docs/checks/M5.md](docs/checks/M5.md)、175 テスト）。14 章の数字は訳している最中の CPU（13%、仕様の 15% は満たす。M5 の目標 5% は未達）を除いて目標内。エンジンの起動は 1.6〜2.3 秒、PDF 15 ページは 111〜114 秒。終了の不具合、VoiceOver の名前と読む順、視差効果・透明度・コントラスト、アイコン、README を足した。残りは M5.md の 7 章。

2026-11-08 夜: M6 を受け取り、レビューで合格とした（[docs/checks/M6.md](docs/checks/M6.md)、217 テスト）。F4 は箇条書きの折り返しが切れ端で訳される不具合を文の規則で直し、見本 6 種で他は 1 ブロックも動かないことを親が再現確認。PDF は訳文の字体が元の PDF に合うようになり（Type 3 フォントの既定値バグ）、同じ 17 ページが 99.4 → 57.7 秒（42% 短縮、訳文 422/422 行一致）。効かなかった 2 変更（is_label エコー、--split-short-lines）は証拠を見て戻した。残件: 字間ラベルの語間の潰れ（BabelDOC 由来、要 monkeypatch）、カード見出しの太さ、表紙の空き。SPEC との差 3 件（M6.md 6.1）は 11-09 に SPEC.md へ反映済み（9 章のまとめ規則、8.2 の起動引数、7.3 の同時数）。

2026-11-08 夜: M7 を実装した（[docs/checks/M7.md](docs/checks/M7.md)、221 テスト、警告 0）。設定と管理の 2 窓だけが対象。設定はタブごとに窓の高さが変わるようにし（前は 6 タブとも 504×405、後は内容ごと）、6 タブの見出し・カード・説明をそろえ、スライダー行を直した。管理は翻訳を原文/訳文のカード + 言語の向きに、履歴の行に EN→JA と相対時刻、用語集の右上に文字つきの読み込む/書き出す、モデルの状態を 1 種類のバッジに、PDF のドロップ領域と失敗行の「詳細」、サイドバーのエンジン状態に色の点。共通のトークンは `Design/Design.swift` と `Design/WindowSizing.swift`。**画面ロックのため撮影（`tools/capture-m7.sh` は用意済み）と VoiceOver の前後比較は未実施**、親のレビュー待ち。

2026-11-08 深夜: M7 を親がレビューして合格にした（[docs/checks/M7.md](docs/checks/M7.md) 8 章）。画面ロックを解いて 24 枚を撮った。翻訳画面の訳文ヘッダーで「コピー」が窓の端で切れ、処理時間が 2 行に折れていたので、処理時間をカードの下へ移した。原文欄は TextEditor の空のスクロールバーの溝を消すため縦長の TextField にした。翻訳と履歴の HSplitView は NavigationSplitView の中で浮いたサイドバーの余白を幅に入れず、サイドバーを細くし右のペインを約 15 pt 窓の外へ押し出していた（M2 から）。HStack + Divider に替えた（ペイン幅のドラッグはなくなる）。221 テスト、警告 0。

次の手: (1) ユーザーが [docs/checks/manual.md](docs/checks/manual.md) の A2・A5・A7 をやり直し、B を行う（B の前に PDF ワーカーの導入が要る）。(2) F4 を自分の画面で試してもらう（M6 で直した件）。(3) ~~SPEC.md に M6.md 6.1 の差分を反映する~~ → 済（11-09）。

## Key Decisions

- 2026-11-06 - UI は SwiftUI + AppKit。GPUI と並べて試作した結果、容量（1.0MB 対 6.6MB）・メモリ（42MB 対 51〜56MB）・コード量・文字とアイコンの質で SwiftUI が上だった（比較は `lab/plamo-pdf-translate/notch-app/`）
- 2026-11-06 - 入口はメニューバーが主役。ノッチは PDF のドロップ先と進み具合だけに使い、設定で切れる（ユーザーの指示: ドラッグ&ドロップにノッチが要るなら使う）
- 2026-11-06 - macOS 26 以降だけに対応し、Liquid Glass を全面に使う（ユーザーの指示）
- 2026-11-06 - v1 は F1〜F4（選択文・入力・PDF・画面）すべてを入れる（ユーザーの指示）
- 2026-11-06 - `MenuBarExtra` ではなく `NSStatusItem` + `NSPanel`。ホットキーから開く API がなく、アイコンへのドロップと開閉の動きを作れないため
- 2026-11-06 - 置き場所は `projects/translate-app/`（ユーザーの指示。`proj-NNN-` の命名より優先）
- 2026-11-09 - 性能レビューの 6 件を直した（[docs/perf-review-2026-11-09.md](docs/perf-review-2026-11-09.md) の「対応の結果」）。訳文が URL キャッシュに残る件、見張りのポーリング、ドラッグごとのペーストボード、履歴検索、PDF の段落ごとの Python 起動。翻訳中の CPU は約 10% の持ち主が SwiftUI と AppKit の更新で、まだ下げられていない
- 2026-11-09 - 置き場所を `~/projects/production/Yaku/` の独立したリポジトリに移した（ユーザーの指示: Murmur と同じ production に置いて開発を続ける）。agentic-os の 8 コミットを `git subtree split` で履歴ごと持ってきた。実物での確認は `.agents/skills/verify-yaku/` に集めた
- 2026-11-06 - 自分だけで使う。配布・Developer ID・公証はしない。署名は自己署名の「Yaku Signing」。開発専用のキーチェーン `yaku-dev.keychain-db` に置く（ログインキーチェーンに置いた「Yaku Dev」は codesign が承認待ちで止まったので使わない）
- 2026-11-06 - 実装は DeepSeek V4.1 Flash の子スレッドに段階ごとに任せ、設計・レビュー・実画面の確認は親が持つ

## Architecture / Structure

- `SPEC.md` - 仕様書（正本）
- `app/` - SwiftPM（`YakuCore` + `Yaku`）。M0 で作る
- `pdf-worker/` - Python + pdf2zh-next。M3 で作る
- `docs/checks/` - 各段階の確認の記録（`M0.md`〜`M4.md`）と、手で確かめる確認表 `manual.md`
- 試作と実験: `lab/plamo-pdf-translate/`（モデル・`.venv`・`notch-app/engine/`）

## Open Questions

- アプリの名前（Yaku は仮）

# translate-app - ローカル翻訳アプリ（仮称 Yaku）

**Created:** 2026-11-06
**Status:** Prototype（M4 完了・撮影済み。手の確認の待ち → M5）

## What We're Building

PLaMo 3 Translate を Mac の中だけで動かし、選んだ文・入力した文・PDF・画面の文字を訳すメニューバー常駐アプリ。SwiftUI + Liquid Glass。仕様は [SPEC.md](SPEC.md)。

## Current Phase

M0・M1 完了（`docs/checks/M0.md`・`M1.md`）。M1 の ⌃⌥J の実地確認は、アクセシビリティの許可を与えてから人が行う → M2 完了（見た目と CPU は画面ロックのため未確認。ロック解除後に親が撮る）→ M3 完了（15 ページ 92.9 秒。見た目は未確認）→ M4 完了（画面の翻訳。最初のブロック 0.41〜0.69 秒。見た目は未確認）。

2026-11-07 夜: ロックが解け、M2〜M4 の撮影 84 枚と計測を済ませた（各 M*.md の 7 章）。撮影で見つかった不具合（重ね表示の文字が 3 倍の大きさ、デモの位置のずれ、短い英文の言語判定、途中で終わった PDF が「処理中」のまま、文言 3 か所）は直してインストール済み（158 テスト）。撮影の手順書は本物のデータを使っていたので、既定を一時のフォルダに変えた。

次: (1) ユーザーが [docs/checks/manual.md](docs/checks/manual.md) の A・B を確かめる（A2・A5・A7 はやり直し。B の前に PDF ワーカーの導入が要る）。(2) M5（磨き込み・性能・アクセシビリティ・アイコン）。M5 で直すもの: 各 M*.md の 7 章の「気づいたこと」、図の中の文字が大きくなる（M3）、2 段組の読む順（M4）、ライセンスのシートが終了を止める疑い（M2）

## Key Decisions

- 2026-11-06 - UI は SwiftUI + AppKit。GPUI と並べて試作した結果、容量（1.0MB 対 6.6MB）・メモリ（42MB 対 51〜56MB）・コード量・文字とアイコンの質で SwiftUI が上だった（比較は `lab/plamo-pdf-translate/notch-app/`）
- 2026-11-06 - 入口はメニューバーが主役。ノッチは PDF のドロップ先と進み具合だけに使い、設定で切れる（ユーザーの指示: ドラッグ&ドロップにノッチが要るなら使う）
- 2026-11-06 - macOS 26 以降だけに対応し、Liquid Glass を全面に使う（ユーザーの指示）
- 2026-11-06 - v1 は F1〜F4（選択文・入力・PDF・画面）すべてを入れる（ユーザーの指示）
- 2026-11-06 - `MenuBarExtra` ではなく `NSStatusItem` + `NSPanel`。ホットキーから開く API がなく、アイコンへのドロップと開閉の動きを作れないため
- 2026-11-06 - 置き場所は `projects/translate-app/`（ユーザーの指示。`proj-NNN-` の命名より優先）
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

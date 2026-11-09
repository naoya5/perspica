# AGENTS.md

Perspica（旧称 Yaku）のコーディングエージェント（Claude Code、Codex など）向けの作業ガイド。`CLAUDE.md` がこのファイルを読み込むので、どのツールも同じルールを読む。

## Perspica とは

メニューバーに常駐する、Mac の中だけで動く翻訳アプリ。選んだ文・入力した文・PDF・画面の文字を訳す。PLaMo 3 Translate（GGUF）を `llama-server` の子プロセスとして動かし、ネットワークには出ない。SwiftUI + AppKit、Swift 6、外部ライブラリなし、macOS 26 以降。 2026-11-09 に Yaku から改名した。見える名前（`Perspica.app`、表示名、画面の文言、アイコン）だけが Perspica で、バンドル ID・データとログの場所・Swift のモジュール名・実行ファイル名・署名・検証スキル `verify-yaku` は Yaku のまま。

## まず読むもの

| ファイル | 何 |
|---|---|
| `SPEC.md` | 仕様の正本。17 章がコードの構成 |
| `context.md` | 決めたこと・進み具合 |
| `docs/checks/M*.md` | 各段階の確認と計測の記録 |
| `.agents/skills/verify-yaku/` | 実物のアプリを動かして確かめる手順（`.claude/skills` はここへのリンク） |

## コマンド

```sh
cd app
swift build              # 警告 0 を保つ
swift test               # 221 テスト
./make-app.sh install    # ~/Applications/Perspica.app を置き換える
```

## 終わったと言う前に

- 動きや見た目を変えたら `verify-yaku` スキルで実物を動かし、証拠（画像・ログ・数値）を残す。テストが通っただけでは終わりではない。
- アプリは同時に 1 つしか起動しない（`Yaku.lock`）。利用者のアプリ、ほかのワークツリーのエージェントと共有している。ロックを持つプロセスを名前で殺さない。
- 本物の履歴・キャッシュ・設定を触らない。デモは必ず `--data-dir` を付ける（ヘルパーが付ける）。
- Claude Code のサンドボックスの中では SwiftPM・`screencapture`・`open` が失敗する。外で走らせる。

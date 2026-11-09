# Perspica

Perspica は、Mac の中だけで動く、メニューバー常駐の翻訳アプリです。どのアプリでも文を選んでキーを押す、パネルに打ち込む、PDF を落とす、画面の文字に重ねる、の 4 通りで訳せます。翻訳は [PLaMo 3 Translate](https://huggingface.co/pfnet/plamo-3-translate-0.8b-GGUF) を Mac の中で動かして行うので、文は外に出ません。

[English README](README.md) · Built with PLaMo

> 画面の言葉は日本語です。53 言語を訳せます。主な組み合わせは日本語と英語です。

## 目次

- [必要なもの](#必要なもの)
- [入れる](#入れる)
- [使い方](#使い方)
- [権限](#権限)
- [モデル](#モデル)
- [プライバシー](#プライバシー)
- [データの置き場所](#データの置き場所)
- [困ったとき](#困ったとき)
- [アンインストール](#アンインストール)
- [ソースからビルドする](#ソースからビルドする)
- [協力する](#協力する)
- [ライセンスと謝辞](#ライセンスと謝辞)

## 必要なもの

| | |
|---|---|
| macOS | 26 以降 |
| Mac | Apple シリコン。エンジンは Metal で動きます |
| Xcode | 26 以降（Swift 6）。アプリのビルドに使います |
| [Homebrew](https://brew.sh) の `llama.cpp` | 翻訳エンジンの `llama-server` が入ります |
| `uv` | PDF を訳すときだけ。アプリが PDF 用の部品を入れるのに使います |

ビルド済みの配布物はありません。このリポジトリからビルドします（数分かかります）。

## 入れる

```sh
brew install llama.cpp uv
git clone https://github.com/naoya5/perspica.git
cd perspica/app
tools/make-signing-identity.sh   # 最初に 1 回。作り直しても権限が外れないようにする
./make-app.sh install            # ビルド・署名して ~/Applications/Perspica.app に置く
open ~/Applications/Perspica.app
```

`make-signing-identity.sh` は、専用のキーチェーンに自己署名のコード署名用の証明書を作ります。飛ばしてもかまいません。その場合はアドホック署名になり、ビルドし直すたびに macOS が権限を聞き直します。公証はしていないので、人に渡すのではなく、各自でビルドしてください。

初めて起動すると、短い案内がモデルの取得まで進めてくれます（[モデル](#モデル)）。

## 使い方

Perspica はメニューバーにいます。

| どこで | キー | 動き |
|---|---|---|
| どこでも | ⌃⌥J | 選んだ文を訳して、選択範囲の下の小さな窓に出す |
| どこでも | ⌃⌥K | パネルを開く / 閉じる |
| どこでも | ⌃⌥O | 画面の文字を読み取り、訳を元の位置に重ねる |
| パネル | ⌘↩ | 訳す |
| パネル | ⌘⇧C | 訳文をコピー |
| パネル | ⌘D | 言語を入れ替える |
| パネル | ⌘O | PDF を開く |
| パネル | ⌘P | ピン（開いたままにする） |
| パネル | ⌘N | 管理画面（履歴・用語集・モデル・PDF）を開く |
| パネル / 選択の窓 | Esc | 閉じる |

⌃⌥J・⌃⌥K・⌃⌥O は **設定 > ショートカット** で変えられます。PDF は、メニューバーのアイコン・パネル・管理画面・ノッチに落とすか、Finder の「このアプリで開く」で渡します。訳した PDF は元のレイアウトのまま、元の PDF の隣（書けなければ `~/Downloads`）に保存されます。

## 権限

使う直前に聞きます。断った場合は、その機能の場所に理由と「システム設定を開く」が出ます。

| 機能 | 権限 |
|---|---|
| ⌃⌥J（選んだ文を読む・置き換える） | アクセシビリティ |
| ⌃⌥O（画面の撮影） | 画面収録 |
| PDF の完了の通知 | 通知 |

## モデル

管理画面の **モデル** から取得します。取得したファイルは SHA-256 で確かめてから使います。

| モデル | 取得 | メモリ | メモ |
|---|---|---|---|
| PLaMo 3 Translate 0.8B（Q4_K_M） | 0.57 GB | 約 1.1 GB | 既定。速い |
| PLaMo 3 Translate 2B（Q4_K_M） | 1.81 GB | 約 2.3 GB | |
| PLaMo 3 Translate 8B（Q4_K_M） | 5.28 GB | 約 5.8 GB | いちばん高品質。16 GB の Mac ではほかのアプリを閉じてから |

モデルは Preferred Networks が [PLaMo Community License](https://plamo.preferredai.jp/info/plamo-community-license-en) で公開しています。最初の取得の前に、アプリが要点を見せて同意を聞きます。手元の GGUF を使うこともできます（**モデル > 既存のファイルを使う**）。

エンジンは最初に訳すときに起動し、10 分使わないと止まります（設定で変えられます）。使っていない間、モデルはメモリに残りません。

## プライバシー

- 翻訳は Mac の中で行います。原文も訳文もどこにも送りません。
- ネットワークを使うのは、Hugging Face からのモデルの取得と、初めて PDF を訳すときの PDF 用の部品（`uv` で PyPI から）とそれが使うフォントやレイアウトのモデルの取得だけです。
- エンジンは `127.0.0.1` でだけ待ち受け、起動ごとに変わるランダムな鍵がないと応えません。
- 履歴と訳のキャッシュは Mac の中に残ります。**設定 > プライバシー** で履歴を残さないようにできます。
- **設定 > プライバシー > 履歴とキャッシュを消す** は、履歴、2 つの訳のキャッシュ（アプリのものと PDF 用の部品のもの）、ログを消します。
- ログには、何をしてどれだけかかったかを書きます。訳した文は書きません。`--data-dir` を付けた開発用の起動だけは、調べるために文も書きます（`YAKU_LOG_CONTENT=0` で止められます）。
- 2026-11-10 より前のビルドでは、PDF 用の部品が `~/.cache/pdf2zh_next` に訳のキャッシュを残していました。pdf2zh-next を単独で使っていなければ、そのフォルダを消してください。

## データの置き場所

| 中身 | 場所 |
|---|---|
| モデル・PDF 用の部品・履歴とキャッシュ | `~/Library/Application Support/Yaku/` |
| ログ | `~/Library/Logs/Yaku/`（`app.log`・`engine.log`・`pdf.log`） |
| 設定 | `defaults read dev.naoya.yaku` |
| 訳した PDF | 元の PDF の隣 |

（2026-11-09 までの名前は Yaku でした。データの場所とバンドル ID はその名前のままです。）

## 困ったとき

| 起きること | 試すこと |
|---|---|
| エンジンが見つからない | `brew install llama.cpp`。`llama-server` を `/opt/homebrew/bin`・`/usr/local/bin`・`~/.local/bin` の順に探します |
| PDF の準備で「uv が見つかりません」 | `brew install uv` のあと、もう一度 PDF を落とす |
| ⌃⌥J で何も起きない | **システム設定 > プライバシーとセキュリティ > アクセシビリティ** を確かめる。アドホック署名で作り直したあとは、一度外してから入れ直す |
| ほかのアプリとキーがぶつかる | **設定 > ショートカット** で変える |
| ほかのこと | `~/Library/Logs/Yaku/app.log` を見てから、Issue を立てる |

## アンインストール

1. メニューバーのメニューから Perspica を終了する。
2. `~/Applications/Perspica.app` を消す。
3. モデル・履歴・ログ・設定も消すなら:

   ```sh
   rm -rf ~/Library/Application\ Support/Yaku ~/Library/Logs/Yaku
   defaults delete dev.naoya.yaku
   ```

4. アクセシビリティや画面収録を許可していたら、**システム設定 > プライバシーとセキュリティ** から Perspica を外す。

## ソースからビルドする

```sh
cd app
swift build          # デバッグビルド。警告 0 が前提
swift test           # 単体テスト
./make-app.sh        # インストールせずに build/Perspica.app を作る
```

コードの構成と、変更が守るルールは [AGENTS.md](AGENTS.md) に、設計の全体は [SPEC.md](SPEC.md) にあります。本物のデータを触らずに試すときは `--data-dir` を付けて起動し、モデルは `YAKU_DEV_MODEL` で渡します。

```sh
YAKU_DEV_MODEL=/path/to/model.gguf \
  app/build/Perspica.app/Contents/MacOS/Yaku --data-dir "$TMPDIR/perspica-demo" --demo-surface panel
```

## 協力する

不具合の報告とプルリクエストを歓迎します。[CONTRIBUTING.md](CONTRIBUTING.md) を見てください。セキュリティの問題は、[SECURITY.md](SECURITY.md) の方法で非公開で知らせてください。

## ライセンスと謝辞

Perspica は [MIT License](LICENSE) で公開しています。

- 翻訳モデル: Preferred Networks の PLaMo 3 Translate（PLaMo Community License）。Built with PLaMo。
- エンジン: [llama.cpp](https://github.com/ggml-org/llama.cpp)（MIT）。Homebrew で別に入れます。
- PDF の翻訳: [pdf2zh-next](https://github.com/PDFMathTranslate/PDFMathTranslate-next) と [BabelDOC](https://github.com/funstory-ai/BabelDOC)、PyMuPDF。どれも AGPL-3.0 です。このリポジトリには含みません。初めて PDF を訳すときにアプリが Mac に入れ、別のプロセスとして動かします。

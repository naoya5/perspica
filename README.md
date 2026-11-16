# Perspica

Perspicaは、Macの中だけで翻訳するメニューバー常駐アプリです。選択したテキスト、パネルに入力した文章、PDF、画面上の文字を翻訳できます。[PLaMo 3 Translate](https://huggingface.co/pfnet/plamo-3-translate-0.8b-GGUF)をローカルで動かし、原文も訳文もMacの外には送りません。

[English](README.en.md) · [Webサイト](https://naoya5.github.io/perspica/) · Built with PLaMo

アプリの表示は日本語です。53言語に対応し、主な翻訳の組み合わせは日本語と英語です。

初回はGitHubでソースコードだけを公開し、ビルド済みアプリの配布は後日に分けます。
公開前の残りの作業は[タスク表](docs/release-tasks.md)にまとめています。

## 目次

- [必要なもの](#必要なもの)
- [インストール](#インストール)
- [使い方](#使い方)
- [権限](#権限)
- [モデル](#モデル)
- [プライバシー](#プライバシー)
- [データの保存先と旧版からの移行](#データの保存先と旧版からの移行)
- [困ったとき](#困ったとき)
- [アンインストール](#アンインストール)
- [ソースからビルドする](#ソースからビルドする)
- [開発への協力](#開発への協力)
- [ライセンスと謝辞](#ライセンスと謝辞)

## 必要なもの

| 項目 | 要件 |
|---|---|
| macOS | 26以降 |
| Mac | Appleシリコン。翻訳エンジンはMetalで動きます |
| Xcode | 26以降（Swift 6）。アプリのビルドに使います |
| [Homebrew](https://brew.sh)の`llama.cpp` | 翻訳エンジンの`llama-server`を提供します |

ビルド済みの配布物はありません。このリポジトリからビルドします。数分かかります。

## インストール

```sh
brew install llama.cpp
git clone https://github.com/naoya5/perspica.git
cd perspica/app
tools/make-signing-identity.sh   # 初回のみ。再ビルド時も同じ署名を使う
./make-app.sh install            # ビルド・署名し、~/Applications/Perspica.app にコピー
open ~/Applications/Perspica.app
```

`make-signing-identity.sh`は、専用のキーチェーンに自己署名のコード署名用証明書を作ります。省略するとアドホック署名になり、ビルドし直すたびにmacOSの権限を設定し直す必要があります。

この手順は自分のMac向けのビルドです。アプリは公証していません。作成したアプリをほかの人へ配布する場合は、署名・公証の扱いと[配布時のライセンス条件](docs/release-licenses.md)を別途確認してください。

初回起動時の案内に沿って、翻訳モデルをダウンロードします。詳しくは[モデル](#モデル)を参照してください。旧Yakuから更新する場合は、[データの移行と権限の再設定](#データの保存先と旧版からの移行)も確認してください。

## 使い方

起動すると、メニューバーにアイコンが表示されます。

| 操作する場所 | キー | 動作 |
|---|---|---|
| どのアプリでも | ⌃⌥J | 選択したテキストを翻訳し、選択範囲の下の小さなウィンドウに表示 |
| どのアプリでも | ⌃⌥K | パネルを開く／閉じる |
| どのアプリでも | ⌃⌥O | 画面上の文字を読み取り、元の位置に訳文を重ねる |
| パネル | ⌘↩ | 翻訳する |
| パネル | ⌘⇧C | 訳文をコピー |
| パネル | ⌘D | 言語を入れ替える |
| パネル | ⌘O | PDFを開く |
| パネル | ⌘P | パネルを開いたままにする |
| パネル | ⌘N | 管理画面（履歴・用語集・モデル・PDF）を開く |
| パネル・選択文のウィンドウ | Esc | 閉じる |

3つのグローバルショートカットは「設定 > ショートカット」で変更できます。

PDFは、メニューバーのアイコン、パネル、管理画面、ノッチへドラッグ&ドロップするか、Finderの「このアプリで開く」から渡します。訳したPDFは元のレイアウトを保ち、元のファイルと同じフォルダに保存します。そこに書き込めない場合は`~/Downloads`に保存します。

## 権限

権限が必要な機能を初めて使う直前に、許可を求めます。許可しなかった場合は、その機能の画面に理由と「システム設定を開く」ボタンを表示します。

| 機能 | 必要な権限 |
|---|---|
| ⌃⌥J（選択したテキストの読み取り・置き換え） | アクセシビリティ |
| ⌃⌥O（画面の撮影） | 画面収録 |
| PDF翻訳の完了通知 | 通知 |

旧Yakuからの更新ではバンドルIDが変わるため、macOSの権限を設定し直してください。同じ署名証明書を使っていても、旧IDの許可は引き継がれません。

## モデル

管理画面の「モデル」からダウンロードします。ファイルのSHA-256ハッシュを確認してから使います。

| モデル | ダウンロード容量 | メモリ使用量の目安 | 補足 |
|---|---|---|---|
| PLaMo 3 Translate 0.8B（Q4_K_M） | 0.57 GB | 約1.1 GB | 初期設定のモデル。高速 |
| PLaMo 3 Translate 2B（Q4_K_M） | 1.81 GB | 約2.3 GB | |
| PLaMo 3 Translate 8B（Q4_K_M） | 5.28 GB | 約5.8 GB | 最も高品質。16 GBのMacでは、ほかのアプリを閉じてから使ってください |

モデルはPreferred Networksが[PLaMo Community License](https://plamo.preferredai.jp/info/plamo-community-license-en)で公開しています。初めてダウンロードする前に、アプリがライセンスの全文を表示し、同意を求めます。手元にあるGGUFファイルも「モデル > 既存のファイルを使う」から指定できます。

エンジンは最初の翻訳時に起動し、10分間使わないと停止します。停止までの時間は設定で変更できます。停止後はモデルがメモリに残りません。

## プライバシー

翻訳はMacの中で行います。原文も訳文も外部へ送信しません。ネットワークを使うのは、Hugging Faceからのモデルのダウンロードだけです。PDFもアプリの中で翻訳し、追加の部品は取得しません。

エンジンは`127.0.0.1`だけで待ち受け、起動ごとに変わるランダムなキーで認証します。履歴と翻訳キャッシュもMac内に保存します。履歴の保存は「設定 > プライバシー」でオフにできます。

通常のログには処理内容と所要時間を記録し、原文や訳文は記録しません。ただし、`--data-dir`を付けた開発用の起動では、調査のためにテキストも記録します。`YAKU_LOG_CONTENT=0`で無効にできます。

「設定 > プライバシー > 履歴とキャッシュを消す」で、履歴、翻訳キャッシュ、ログを削除します。

2026-11-13までのビルドは、PDF翻訳にPythonのPDFワーカーを使っていました。アプリは起動時に、その残りのファイル（`Perspica/pdf-worker`と`Perspica/pdf-worker-home`）を削除します。2026-11-10より前のビルドは、翻訳キャッシュを`~/.cache/pdf2zh_next`にも残していました。pdf2zh-nextを単独で使っていなければ、このフォルダを削除してください。

## データの保存先と旧版からの移行

| 内容 | 保存先 |
|---|---|
| モデル・履歴・翻訳キャッシュ | `~/Library/Application Support/Perspica/` |
| 履歴などのデータベース | 上記フォルダ内の`Perspica.store` |
| ログ | `~/Library/Logs/Perspica/`（`app.log`・`engine.log`） |
| 設定 | `defaults read app.perspica` |
| macOSのアプリ用キャッシュ（作成された場合） | `~/Library/Caches/app.perspica/` |
| 翻訳済みPDF | 元のファイルと同じフォルダ（書き込めなければ`~/Downloads`） |

現在のバンドルIDは`app.perspica`、単一起動のロック名は`Perspica.lock`です。

旧称はYakuです。通常の起動時に、旧`~/Library/Application Support/Yaku/`のデータと`~/Library/Logs/Yaku/`のログを新しい保存先へ移します。移行の記録をディスクに残すため、中断しても次の通常起動で再開します。新しい保存先に同名のファイルがあれば新しい側を優先し、競合した旧ファイルはそのまま残します。ストアとその付随ファイルも新しい名前に変えます。

旧`dev.naoya.yaku`の既知の設定項目は一度だけコピーし、新しい設定に値があれば上書きしません。アプリが管理するパスは新しい保存先に書き換えます。旧設定はバックアップとして残します。

旧PDFワーカーのPython環境は移動できないため、旧`Yaku/`フォルダにバックアップとして残します。今のPDF翻訳はこの環境を使いません。

既存の`Yaku.lock`がある場合は、旧版との同時起動を防ぐために併用します。新規インストールでは旧Yakuのフォルダを作りません。バンドルIDの変更に伴い、アクセシビリティや画面収録などの権限は再設定が必要です。

`--data-dir`を指定した開発・検証用の起動では、実データや実設定の移行を行いません。ログも実利用の保存先と分け、指定先の`logs/`へ保存します。

Swiftのモジュール名と実行ファイル名（`Yaku`・`YakuCore`）、環境変数`YAKU_DEV_MODEL`、検証スキル`verify-yaku`は旧名のままです。

## 困ったとき

| 症状 | 確認すること |
|---|---|
| エンジンが見つからない | `brew install llama.cpp`を実行してください。アプリは`/opt/homebrew/bin`、`/usr/local/bin`、`~/.local/bin`から`llama-server`を探します |
| ⌃⌥Jで何も起きない | 「システム設定 > プライバシーとセキュリティ > アクセシビリティ」を確認してください。旧Yakuからの更新やアドホック署名での再ビルド後は、一度登録を外して追加し直してください |
| ほかのアプリとショートカットが重なる | 「設定 > ショートカット」で変更してください |
| そのほかの問題 | `~/Library/Logs/Perspica/app.log`を確認し、[不具合を報告](https://github.com/naoya5/perspica/issues/new/choose)してください。添付するログから私的な情報を除いてください |

## アンインストール

1. メニューバーのメニューからPerspicaを終了します。
2. `~/Applications/Perspica.app`を削除します。
3. モデル・履歴・ログ・設定も削除する場合は、次のコマンドを実行します。この操作は取り消せません。

   ```sh
   rm -rf "$HOME/Library/Application Support/Perspica" "$HOME/Library/Logs/Perspica" \
     "$HOME/Library/Caches/app.perspica"
   defaults delete app.perspica
   ```

4. アクセシビリティや画面収録を許可していた場合は、「システム設定 > プライバシーとセキュリティ」からPerspicaを外します。

上の操作では、旧Yakuの設定、旧PDFワーカー環境、移行時に競合して残ったファイルは削除しません。これらが不要になった場合は、旧`~/Library/Application Support/Yaku/`と`~/Library/Logs/Yaku/`の内容を確認してから削除してください。旧設定は`defaults delete dev.naoya.yaku`で削除できます。

## ソースからビルドする

リポジトリのルートから実行します。

```sh
cd app
swift build          # デバッグビルド。警告は0件
swift test           # 単体テスト
./make-app.sh        # インストールせずに build/Perspica.app を作る
cd ..
```

コードの構成と開発時のルールは[AGENTS.md](AGENTS.md)、設計仕様は[SPEC.md](SPEC.md)にあります。実データに触れずに試す場合は、`--data-dir`で保存先を分け、`YAKU_DEV_MODEL`でモデルを指定します。

```sh
YAKU_DEV_MODEL=/path/to/model.gguf \
  app/build/Perspica.app/Contents/MacOS/Yaku --data-dir "$TMPDIR/perspica-demo" --demo-surface panel
```

## 開発への協力

不具合の報告とプルリクエストを歓迎します。手順は[CONTRIBUTING.md](CONTRIBUTING.md)を参照してください。セキュリティの問題は、[SECURITY.md](SECURITY.md)の手順で非公開で報告してください。

## ライセンスと謝辞

Perspicaのコードは[MITライセンス](LICENSE)です。マスコットのPolly、アプリアイコン、紹介動画はMITの対象外で、扱いは[ARTWORK.md](ARTWORK.md)に書いています。PDF翻訳もSwiftとAppleの標準フレームワークだけで実装しており、AGPLなどのPDFライブラリは使っていません。翻訳モデルとエンジンには、それぞれ元のライセンスが適用されます。

公開前の確認は未完了です。[公開までのタスク](docs/release-tasks.md)、[配布物とソースの対応](docs/source-distribution-scope.md)、[THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md)、[配布時のライセンス確認事項](docs/release-licenses.md)を参照してください。

- 翻訳モデル: Preferred NetworksのPLaMo 3 Translate（PLaMo Community License）。Built with PLaMo。
- エンジン: [llama.cpp](https://github.com/ggml-org/llama.cpp)（MIT）。Homebrewで別途インストールします。
- PDF翻訳: Perspica自身のSwiftコード（Core Graphics、Core Text、PDFKit）。訳したPDFには、macOSに含まれるヒラギノフォントのサブセットを埋め込みます。

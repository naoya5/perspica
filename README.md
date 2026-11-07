# Yaku

メニューバーに常駐する、Mac の中だけで動く翻訳アプリ。選んだ文・入力した文・PDF・画面の文字を訳す。
PLaMo 3 Translate（GGUF）を llama-server の子プロセスとして動かし、ネットワークには出ない。

仕様は [SPEC.md](SPEC.md)。各段階の確認の記録は [docs/checks/](docs/checks/) にある。

## 入れる

```sh
cd projects/translate-app/app
./make-app.sh install     # ビルド・署名して ~/Applications/Yaku.app に置く
open ~/Applications/Yaku.app
```

macOS 26 以降。署名は自己署名の「Yaku Signing」で、開発用のキーチェーン `yaku-dev.keychain-db` を使う（`make-app.sh` が開く）。
配布用の Developer ID と公証は作っていない。

初回は次の 2 つが要る。

1. **モデル**: メニューバーのアイコン →「管理画面」→「モデル」から 0.8B（0.57GB）を取得する。PLaMo Community License に同意する。開発中は `~/Library/Application Support/Yaku/` の外にある GGUF を「既存のファイルを使う」で選べる
2. **PDF を訳す場合**: 初めて PDF を落としたときに「PDF の翻訳には追加の部品が必要です」と聞くので、`uv` で入れる（`~/Library/Application Support/Yaku/pdf-worker/`）

## 使い方

| どこで | キー | 動き |
|---|---|---|
| どこでも | ⌃⌥J | 選んだ文を訳す（選択範囲の下に HUD） |
| どこでも | ⌃⌥K | パネルを開く / 閉じる |
| どこでも | ⌃⌥O | 画面の文字を読み取り、訳を元の位置に重ねる |
| パネル | ⌘↩ | 訳す |
| パネル | ⌘⇧C | 訳文をコピー |
| パネル | ⌘D | 言語を入れ替える |
| パネル | ⌘O | PDF を開く… |
| パネル | ⌘P | ピン（開いたままにする） |
| パネル | ⌘N | 管理画面を開く |
| パネル / HUD | Esc | 閉じる |
| HUD | ⌘C / ⌘↩ / Tab / ⌥（押している間）/ ⌘O | コピー / 置き換え / 文体 / 原文 / パネルで開く |
| 重ね表示 | Esc / ⌥（押している間）/ ⌘C | 閉じる / 原文 / すべてコピー |
| 管理画面 | ⌘1〜⌘5 | サイドバーの項目 |

⌃⌥J・⌃⌥K・⌃⌥O は設定の「ショートカット」で変えられる。
PDF はメニューバーのアイコン・パネル・管理画面・ノッチ・Finder の「このアプリで開く」のどこに落としてもよい。

## 権限

使う直前に聞く。断られたら、その機能の場所に理由と「システム設定を開く」を出す。

| 機能 | 権限 |
|---|---|
| ⌃⌥J（選んだ文を読む・置き換える） | アクセシビリティ |
| ⌃⌥O（画面の撮影） | 画面収録 |
| PDF の完了の通知 | 通知 |
| ログイン時に起動 | なし（システム設定の「ログイン項目」に出る） |
| ホットキー・ドロップ・文字の読み取り | なし |

## データの置き場所

| 中身 | 場所 |
|---|---|
| モデル・PDF ワーカー・履歴とキャッシュ | `~/Library/Application Support/Yaku/` |
| ログ | `~/Library/Logs/Yaku/app.log` |
| 出力した PDF | 元の PDF の隣（書けなければ `~/Downloads`） |

履歴とキャッシュは設定の「プライバシー」で消せる。

## 作り直す

```sh
cd projects/translate-app/app
swift build              # YakuCore + Yaku
swift test               # 175 テスト
./make-app.sh            # build/Yaku.app を作って署名
./make-app.sh install    # ~/Applications/Yaku.app を置き換える
```

開発用の起動オプション（`--demo-*`）と計測・撮影の道具は `app/tools/` にある。
画面を出して確かめるときは `--data-dir "$TMPDIR/yaku-demo-data"` を付けて、本物のデータを触らないようにする。

```sh
app/build/Yaku.app/Contents/MacOS/Yaku --data-dir "$TMPDIR/yaku-demo-data" \
    --demo-surface panel --demo-state translating --demo-pin
```

アイコンは `app/Resources/Yaku.icon`（Icon Composer の文書）で、`make-app.sh` が `xcrun actool` で `Assets.car` と `Yaku.icns` にコンパイルする。
絵を描き直すときは `swiftc -O app/tools/make-icon.swift -o /tmp/make-icon && /tmp/make-icon app/Resources/Yaku.icon/Assets`。

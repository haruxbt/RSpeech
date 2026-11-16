# RSpeech

Safariで開いているページの本文を、VOICEVOXの同じ声で読み上げる小さなMacアプリです。
日本語の途中に英単語があっても、Appleの英語音声へ切り替わりません。

## ダウンロード

**[最新版のダウンロード](https://github.com/haruxbt/RSpeech/releases/latest)** から `RSpeech-v1.1.0-macOS-arm64.zip` を取得してください。ソースコードのZIPではなく、Releases内のアプリ用ZIPを使います。

1. ZIPを展開します。
2. `RSpeech.app` を「アプリケーション」へコピーします。
3. Safariで読みたいページを開き、RSpeechの **▶** を押します。

Apple Silicon向けです。PythonやXcodeの別途インストールは不要です。アプリは仮署名・未公証です。初回起動でmacOSの確認が必要になる場合があります。

## 使い方

- **▶**：現在のSafariページの本文を取得して読み上げます。
- **⏸**：一時停止します。もう一度 **▶** を押すと続きから再開します。
- 再生・再開時にSafariのURLが変わっていた場合、以前の本文と再生位置を破棄し、新しいページの本文を先頭から読みます。
- 同じURLでは取得済みの本文を使います。最後まで読み終わった後の **▶** は先頭から再生します。
- **声・速度**を選べます。変更する場合は、読み上げの終了を待つか、メニューバーのRSpeechから「読み上げを停止」を選んでください。
- **「取得した本文」**を広げると、読み上げ対象を確認・コピーできます。

記事本文の領域を優先して、記事タイトル・サイトのヘッダー・ナビゲーション・フッターなどを除外します。本文中の小見出しは読みます。ページ構造によっては不要な文が混ざったり、本文を取得できなかったりする場合があります。
同じURLのまま内容だけが更新されるページでは、メニューバーから終了して起動し直すと取り直せます。
画像・PDFのOCR、翻訳、ページの自動スクロールには対応していません。

## Safariの初回設定

macOSがSafariの操作許可を求めた場合は、ご本人が内容を確認して許可してください。拒否した場合は、システム設定 → プライバシーとセキュリティ → オートメーションでRSpeechのSafari操作許可を確認します。

SafariでJavaScriptの実行が禁止されている場合は、Safariの設定 → 詳細で開発者向け機能を表示し、開発メニューの **「Apple EventsからのJavaScriptを許可」** を有効にしてください。OSによって表示名は異なります。

## 音声・プライバシー

四国めたん・ずんだもん・春日部つむぎ・雨晴はう・冥鳴ひまり・雀松朱司のノーマル音声を選べます。速度は0.75〜2倍です。英単語の発音はVOICEVOXの辞書に依存します。

本文・URL・生成音声はメモリで扱い、保存・ログ出力・外部送信しません。音声合成用のHTTPサーバーも起動しません。声と速度の設定だけをこのMacに保存します。Safari自体による通常の閲覧通信は別です。

そのMacにR翻訳の共有モデル `~/Library/Application Support/RTranslate/Assets/voicevox` が揃っていれば優先して再利用します。なければ、アプリに同梱した予備モデルを使います。R翻訳の設定やファイルは変更しません。

音声を公開する場合は、[第三者ライセンス・声ごとの規約](THIRD_PARTY_NOTICES.md)とクレジット条件を確認してください。

## 開発

ビルドにはmacOSのCommand Line Toolsが必要です。音声実行環境は、ダウンロード済みRSpeechアプリから再利用できます。

```sh
python3 build.py --seed-app /Applications/RSpeech.app --output dist/RSpeech.app
```

初回の実行環境は既存RTranslateのローカル開発環境からも構成できます。ビルドはモデル等を新たにダウンロードしません。Python・モデル・ビルド成果物はGit管理から除外しています。

```sh
python3 Tests/run_reader_checks.py
npm install
npm test
dist/RSpeech.app/Contents/MacOS/RSpeech --self-test
dist/RSpeech.app/Contents/MacOS/RSpeech --audio-self-test --bundled-model-test
```

再生状態・URL切替・取得失敗・取得中の停止/ページ遷移、タイトル除外・段落順序などを検証します。
Safariでの手動確認には `python3 Tests/serve_fixture.py` を起動し、表示されたURLと `/b.html` を使えます。

Mac miniで動作を確認しています。MacBook Airでの起動・速度・メモリ使用量は未検証です。

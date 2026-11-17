# RSpeech 共通読み上げ辞書

`common-ja.json` はアプリの起動時に取得する公開データです。VOICEVOXのモデルやOpen JTalk基本辞書ではなく、RSpeech用の単語・読み・アクセント・優先度の対応表です。

## 対象と作成

IT・プログラミング・AI開発・セキュリティ、ネットワークメーカー・製品名を対象としています。Intent / Planner / Write、PUT / GET / POST / read / write、Cisco / Catalyst / Fortinet / Palo Altoなどを含みます。

`collect_candidates.py` で明示した8つの公開ページから語彙候補を抽出し、`candidates.json` に単語と出現数だけを記録しています。本文や閲覧履歴は保持しません。その候補に一般的なIT用語や利用者から指定された製品名・読みを補い、`readings.tsv` でカタカナ読みを編集しています。全項目が抽出ページに掲載されているわけではありません。

公開ページの用語掲載は出典として記録していますが、読みは本プロジェクトの編集方針です。公式の発音やアクセントを保証するものではありません。初期アクセントは0（平板）、優先度は5です。個人辞書の修正を優先します。

## 更新

1. `readings.tsv` の単語と読みを編集します。
2. アクセント・優先度を変更する場合は `pronunciation-overrides.json` の同じ単語の値を更新します。個人辞書から取り込む場合も、読み・アクセント・優先度を上書きし、個人のUUIDや設定は公開しません。
3. `build_dictionary.py` のversionを上げます。
4. `python3 Dictionary/build_dictionary.py` でJSONを生成します。
5. `Tests/check_common_dictionary.py --app ...` で全項目をVOICEVOX Coreで検証します。
6. mainへ公開すると、アプリの次回起動時または「今すぐ更新」で取得されます。アプリの再配布は不要です。

自動更新URL：
https://raw.githubusercontent.com/haruxbt/RSpeech/main/Dictionary/common-ja.json

## JSON形式

```json
{
  "schemaVersion": 1,
  "version": "2026.11.16.1",
  "entries": [
    { "word": "ARTEX", "reading": "アルテックス", "accent": 0, "priority": 5 }
  ]
}
```

文字・読みは各64文字まで。読みはカタカナ、accentは0〜モーラ数、priorityは0〜10です。英字の大文字・小文字を区別せず、同一単語を重複登録できません。

アプリは公開JSONの取得だけを行います。ページ・URL・個人の登録内容は送信しません。取得データを検証してから保存し、通信失敗・不正データ・旧版の場合は手元の辞書を保持します。

RSpeech形式のJSON配列、およびVOICEVOX Engineが書き出すUUIDをキーとしたJSONから、文字・読み・アクセント・優先度を個人辞書へ取り込めます。品詞は一般名詞として扱います。書き出しはRSpeech形式の個人辞書です。VOICEVOX EngineのHTTPサーバーは必要ありません。

## 2026.11.16.2

共通辞書を833語へ更新しました。Attack Surface / MITRE ATT&CK / MITRE Att@ck / Tor / Dark Web / DoS / DDoSを含みます。Torは利用者指定の「トア」です。アプリ1.3.0は同梱初期版789語から起動時にこのJSONへ更新します。アプリの再インストールは不要です。

## 2026.11.17.1

提供された18語の読み・アクセント・優先度を反映し、850語へ更新しました。個人のUUIDは取り込みません。RSpeech 1.4.0以降では、更新後に同一内容の個人登録を整理し、異なる読み・アクセント・優先度は保持します。

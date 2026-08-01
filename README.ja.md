# zip-porter

Windows と安全にやり取りできる ZIP の作成・展開を行う macOS アプリ
（Swift/AppKit 製）。

zip-porter は MacWinZipper（作成側）と The Unarchiver（展開側・ZIP 用途）の
組み合わせを、広告なし・MIT ライセンス・完全ローカル動作の単一アプリで
置き換えます。

- **作成**: Windows で正しく開ける ZIP を作る — macOS の不要ファイル
  （`.DS_Store`、`__MACOSX/`、AppleDouble `._*`）を除去し、ファイル名は
  NFC 正規化した UTF-8 で格納（「テ゛ータ」のような濁点分離を解消）。
  パスワード保護（AES-256）を標準搭載
- **展開**: Windows 製 ZIP を正しく開く — CP932（Shift_JIS）ファイル名を
  自動判定してデコードし、ZipCrypto / AES 暗号化アーカイブの両方に対応
- **レガシー互換は opt-in**: `--cp932` で古い日本語 Windows ツール向けの
  ファイル名格納、`--zipcrypto` で Windows Explorer 単体で開ける
  アーカイブを作成（強度警告あり）

> **Status: エンジン＋CLI＋GUI 完成（RFP Phase 1–2）、リリース前。**
> 全体仕様は [RFP](docs/ja/zip-porter-rfp.ja.md) を参照してください。

## GUI

ZipPorter を起動してウィンドウにドロップするだけです:

- **ファイル/フォルダをドロップ** → オプションシート（パスワード・CP932・
  ZipCrypto）が表示され、Windows で安全に開ける ZIP を入力と同じ場所に作成。
  シートは設定を記憶し、「次回から表示しない」でスキップ可（設定画面で復帰）
- **`.zip` をドロップ**（またはダブルクリック — ZipPorter は ZIP の
  ハンドラとして登録されます）→ 展開。暗号化 ZIP はパスワードを確認
- **設定（⌘,）** — The Unarchiver 風の展開設定: 展開先（同じフォルダ/
  毎回確認/固定フォルダ）、新規フォルダ作成（しない/複数最上位項目のみ/
  常に）、作成フォルダの変更日、Finder に表示、アーカイブをゴミ箱へ

## CLI

同じアプリのバイナリがそのまま CLI としても動作します:

```
zip-porter pack <input>... [-o <output.zip>] [--password] [--cp932] [--zipcrypto] [--no-clean]
zip-porter unpack <input.zip> [-o <dest-dir>] [--password] [--encoding auto|utf8|cp932]
zip-porter inspect <input.zip>
zip-porter --version
```

コマンドなしで起動すると GUI が立ち上がります。

### pack（作成）

- macOS の不要ファイル（`.DS_Store`、`__MACOSX/`、AppleDouble `._*`、
  Finder `Icon\r`、Spotlight/fseventsd/Trashes）を除去 — `--no-clean` で無効化
- ファイル名は NFC 正規化した UTF-8（UTF-8 フラグ付き）。`--cp932` で
  CP932 格納に切替（CP932 で表現できない名前はエラー）
- `--password` は対話プロンプトでパスワード入力（argv に平文を残さない）し
  AES-256（WinZip AE-2）で暗号化。`--zipcrypto` は Explorer 単体で開ける
  弱い暗号（警告表示あり）
- 圧縮済み拡張子（jpg, png, mp4, zip など）は store、その他は deflate。
  シンボリックリンクはスキップ
- 既存の出力名は上書きせず「name 2.zip」形式で回避

### unpack（展開）

- ファイル名エンコーディング自動判定: UTF-8 フラグ優先。フラグなしは
  UTF-8 妥当性検査を先に行い、妥当でなければ CP932。
  `--encoding utf8|cp932` で強制指定可
- ZipCrypto / AES-128/192/256（AE-1/AE-2）を展開可能。必要時に
  パスワードをプロンプト
- トップレベルが単一ならそのまま、複数なら ZIP 名のフォルダにラップ。
  既存ファイルは上書きせず「name 2」形式
- zip-slip 対策: 絶対パス・`..`・ドライブレター・NTFS ADS 名は
  スキップ（警告表示）。シンボリックリンクエントリもスキップ
- 既定は ZIP と同じフォルダに展開。`-o <dir>` 指定時は `unzip -d` 同様
  必要なら作成

### inspect（診断）

各エントリのサイズ・圧縮方式・暗号方式・UTF-8 フラグと、アーカイブ全体の
名前エンコーディング判定結果・macOS 不要ファイル混入を表示します。
展開前の文字化け原因調査に使えます。

## 動作環境

- macOS 14+（Apple Silicon）

## ビルド

```
make build      # swift build -c release
make test       # swift test
make build-app  # dist/ZipPorter.app の組み立て + Developer ID 署名
make package    # notarize + staple + リリース用 zip 作成
```

## Windows 側の受信者への注意

- AES-256 暗号化 ZIP は Windows では 7-Zip 等が必要です — Explorer 単体では
  開けません。相手が Explorer しか使えない場合は `--zipcrypto` を使って
  ください（暗号強度は弱く、警告が表示されます）。

## ライセンス

MIT

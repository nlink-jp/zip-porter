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

> **Status: scaffold.** エンジン（Phase 1）を開発中です。全体仕様と計画は
> [RFP](docs/ja/zip-porter-rfp.ja.md) を参照してください。

## 使い方

GUI アプリのバイナリがそのまま CLI としても動作します:

```
zip-porter pack <input>... [-o <output.zip>] [--password] [--cp932] [--zipcrypto] [--no-clean]
zip-porter unpack <input.zip> [-o <dest-dir>] [--password] [--encoding auto|utf8|cp932]
zip-porter inspect <input.zip>
zip-porter --version
```

コマンドなしで起動すると GUI が立ち上がります（ファイルをドロップで圧縮、
`.zip` をドロップで展開）。

`pack` / `unpack` / `inspect` は未実装です。

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

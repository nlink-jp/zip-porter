# RFP: zip-porter

> Generated: 2026-08-01
> Status: Draft

## 1. Problem Statement

macOS と Windows の間で ZIP ファイルをやり取りする際、OS 標準ツールでは次の問題が
避けられない。

- **作成時**: Finder の「圧縮」は `.DS_Store` / `__MACOSX/` / `._*`（AppleDouble）を
  混入させ、ファイル名を UTF-8 NFD（濁点分離）で格納するため、Windows 側で
  「テ゛ータ」のような表示崩れや、レガシー解凍ツールでの文字化けが起きる。
  また GUI からパスワード付き ZIP を作成できない。
- **展開時**: アーカイブユーティリティは Windows 製の CP932（Shift_JIS）ファイル名
  ZIP を文字化けさせ、AES 暗号化 ZIP を展開できない。

従来この穴を MacWinZipper（作成側）と The Unarchiver（展開側）で埋めていたが、
MacWinZipper は配布ライセンスの制約とアプリ内広告の導入により常用に適さなく
なった。**zip-porter** は、この「Windows と安全に往復できる ZIP の作成・展開」を
単一のクリーンな（MIT ライセンス・広告なし・完全ローカル動作）ネイティブ macOS
アプリで置き換える。

対象ユーザーは、日本語ファイル名を含む ZIP を Windows 環境（取引先・社内の
Windows ユーザー）と日常的にやり取りする macOS ユーザー。

## 2. Functional Specification

### Commands / API Surface

単一バイナリ。GUI アプリの実行ファイルが CLI サブコマンドにも応答する
（`NSApplicationMain` 前に argv でルーティング。shell-agent v0.7.0 /
grid-edit `--version` で実証済みのパターン）。

```
zip-porter pack <input>... [-o <output.zip>] [--password] [--cp932] [--zipcrypto] [--no-clean]
zip-porter unpack <input.zip> [-o <dest-dir>] [--password] [--encoding auto|utf8|cp932]
zip-porter inspect <input.zip>
zip-porter --version
```

**pack（作成）** — デフォルト動作:

- ファイル名は UTF-8（general purpose bit 11 セット）＋ **NFC 正規化**
- 除外リスト適用: `.DS_Store`, `._*`, `__MACOSX/`, `Icon\r`, `.fseventsd`,
  `.Spotlight-V100`, `.Trashes`（`--no-clean` で無効化）
- パスワード指定時は **AES-256（WinZip AE-2 形式）**
- opt-in フラグ: `--cp932`（ファイル名を CP932 で格納、レガシー Windows 向け）、
  `--zipcrypto`（Explorer 単体で展開可能な従来暗号。強度が弱いことを警告表示）
- 出力名: 入力が 1 つなら `<basename>.zip` を同階層に生成。複数入力は `-o` 必須
- リソースフォーク・拡張属性は格納しない（Windows 往復用途のため）

**unpack（展開）** — デフォルト動作:

- ファイル名エンコーディング自動判定: bit 11 → UTF-8 確定。フラグなしは
  CP932 デコード試行を優先し、失敗時に UTF-8 妥当性検査へフォールバック
  （ASCII のみは両立するのでそのまま）。`--encoding` で強制指定可
- ZipCrypto / AES-128/192/256（AE-1/AE-2）の両方を展開可能。パスワードは
  対話プロンプト（端末エコーなし）で取得
- 展開先: ZIP と同階層。トップレベルが複数エントリの場合は
  `<zip 名>/` フォルダにラップ（The Unarchiver 同等）
- 既存パスとの衝突時は上書きせず `名前 2` 形式の一意名を採用
  （アーカイブユーティリティ同等）
- **zip-slip 対策必須**: `../` を含むパス・絶対パスは展開先外に出さない。
  symlink エントリは既定でスキップ

**inspect（診断）** — エントリ一覧に加え、判定したファイル名エンコーディング・
暗号方式・UTF-8 フラグ有無・不要ファイルの混入を表示する。文字化け ZIP の
原因調査と `--encoding` 指定の判断材料に使う。

**GUI**:

- ドロップゾーン 1 枚のシンプルなウィンドウ。バージョン表記を常時表示
- フォルダ/ファイルをドロップ → **オプションシート**（出力先・パスワード有無・
  互換モード CP932/ZipCrypto トグル）を毎回表示して作成。シートの既定値は
  前回値を記憶し、設定でシートスキップ（即作成）も選択可
- `.zip` をドロップ → 展開（暗号化されていればパスワード入力シート）
- `.zip` のダブルクリック関連付け（`LSHandlerRank` は grid-edit と同じ方針で
  Default を主張）→ 同階層に展開
- 進捗表示とキャンセル。エラーはダイアログで明示

### Input / Output

- 入力: ローカルのファイル/フォルダ、および ZIP ファイル
- 出力: ZIP ファイル、展開されたファイルツリー
- CLI の診断出力（inspect）は人間可読テキスト。終了コードで成否を返す
- ネットワーク I/O は一切行わない

### Configuration

- CLI: フラグのみ（設定ファイルなし。単機能ツールに config は過剰）
- GUI: UserDefaults（シート既定値の記憶、シートスキップ、互換モード既定）

### External Dependencies

なし。完全ローカル動作。Apple 標準フレームワーク（AppKit, Foundation,
CommonCrypto, Compression）のみで、サードパーティ依存を持たない。

## 3. Design Decisions

- **Swift/AppKit ネイティブ（grid-edit 路線）**: GUI 主体のツールであり、
  Finder/Dock 統合（ドロップ・関連付け）とネイティブな操作感を最優先。
  csv-editor（Wails）→ grid-edit の置換で得た「WebView 製 UI は macOS
  ネイティブ体験に到達できない」という結論を踏襲する
- **単一バイナリ CLI 同居**: 別バイナリ同梱はビルドターゲット増・パス解決・
  署名の複雑化を招くため不採用（組織の既知知見）
- **SPM 2 ターゲット構成**: `ZipPorterCore`（UI 非依存エンジン: ZIP R/W、
  エンコーディング変換、暗号。AppKit import 禁止・テスト必須）＋
  `ZipPorter`（AppKit アプリ＋CLI ルーティング）。grid-edit と同型
- **暗号の自前実装**: WinZip AES（AE-2: PBKDF2-HMAC-SHA1 1000 iter、
  AES-CTR リトルエンディアンカウンタ、HMAC-SHA1 認証）と ZipCrypto を
  CommonCrypto（`CCKeyDerivationPBKDF` / `CCCrypt` CTR モード）ベースで実装。
  仕様は公開されており決定的にテスト可能。**7-Zip / Info-ZIP / Windows 標準で
  生成した実 ZIP をテストフィクスチャとして相互検証する**ことを受け入れ条件と
  する
- **デフォルトは現代寄り**: Windows 10/11 の Explorer は UTF-8 フラグ付き ZIP を
  正しく扱えるため、既定は UTF-8＋NFC / AES-256。CP932 / ZipCrypto は
  レガシー受信環境向けの opt-in。MacWinZipper が前提とした Win7 時代とは
  環境が変わった
- **明示的スコープ外**: 7z / RAR / tar 等の他形式（The Unarchiver・Keka を併用
  継続）、Windows / Linux バイナリ、ZIP64 超巨大アーカイブの最適化（読み書きの
  正しさは担保するが性能チューニングは後回し）、ファイル名の暗号化（ZIP 仕様に
  存在しない）、クラウド連携
- **補完関係**: 既存 nlink-jp ツールとの重複なし。商用外部アプリ 2 本の置換

## 4. Development Plan

### Phase 1: Core（エンジン＋CLI）

- `ZipPorterCore`: ZIP リーダ/ライタ、NFC 正規化、CP932⇔UTF-8 変換、
  エンコーディング自動判定、ZipCrypto/AES 暗号復号、除外フィルタ、
  zip-slip ガード
- CLI サブコマンド（pack/unpack/inspect/--version）完成
- テスト: ユニット＋相互検証フィクスチャ（7-Zip・Info-ZIP・Windows 標準
  『圧縮フォルダー』で生成した ZIP の展開、生成 ZIP の Windows 側展開確認）
- **独立レビュー可能**: CLI として完結し、実データ E2E ができる

### Phase 2: GUI

- ドロップウィンドウ、オプションシート、パスワードシート、進捗/キャンセル
- `.zip` 関連付け（Info.plist document type + LSHandlerRank）
- en/ja ローカライズ（grid-edit の .lproj パターン）
- **独立レビュー可能**: Phase 1 の CLI が回帰基準になる

### Phase 3: Release

- 署名＋notarize＋staple、GitHub Releases（zip 検証: Developer ID /
  `--version` 応答）、homebrew-tap cask、util-series submodule 統合、
  catalog / org profile 更新、check-org.sh 全緑
- README.md / README.ja.md / CHANGELOG.md / AGENTS.md 完備

## 5. Required API Scopes / Permissions

なし（外部サービス・API・認証情報は一切使用しない）。
macOS 上の権限も特別なものは不要（サンドボックス外・ユーザー選択ファイルのみ）。

## 6. Series Placement

Series: **util-series**

Reason: 汎用のデータ変換・処理ツールであり、セキュリティ調査（cybersecurity）
や LLM（lite）の性格を持たない。GUI 主体ツールの util-series 配置は grid-edit /
url-shelf / share-mounter の前例に一致する。開始は CONVENTIONS.md に従い
`_wip/zip-porter/` で行い、リリース時に util-series へ submodule 統合する。

## 7. External Platform Constraints

- **Windows Explorer（受信側）**: Windows 10/11 は UTF-8 フラグ付きファイル名と
  ZipCrypto 暗号 ZIP の展開に対応。**AES 暗号 ZIP は非対応**（受信者に 7-Zip 等が
  必要）→ README に受信者向け注意を明記し、Explorer 単体要件の相手には
  `--zipcrypto` を案内する
- **レガシー日本語環境**: 古い解凍ツール（Lhaplus 等）は UTF-8 フラグを解さず
  CP932 前提 → `--cp932` opt-in で対応
- **ZipCrypto の脆弱性**: 既知平文攻撃で破られうる。互換性のためだけに提供し、
  選択時は GUI/CLI ともに警告を出す
- **macOS Gatekeeper**: 配布には Developer ID 署名＋notarization が必須
  （組織の確立済みプロセス）
- 対象 OS: macOS 14+ / arm64 prebuilt（grid-edit と同一ポリシー）

---

## Discussion Log

1. **課題整理**: OS 標準ツールの問題を作成/展開の両面で分解。MacWinZipper=作成側、
   The Unarchiver=展開側という既存アプリの役割を確認し、広告・ライセンス問題を
   受けて自前置換の方針を確認
2. **スコープ**: The Unarchiver の完全置換（多形式展開）は規模過大と判断し
   **ZIP 専用**に確定。7z/RAR は既存アプリ併用を継続
3. **形態**: 「GUI 主体＋CLI サブコマンド同居（単一バイナリ）」をユーザー指定。
   組織の実証済みパターンに一致
4. **デフォルト方針**: 「現代寄り」（UTF-8+NFC / AES-256、レガシーは opt-in）を
   採用。Win10/11 の UTF-8 フラグ対応が根拠
5. **GUI 技術**: Wails（Go エンジンが枯れている）と Swift ネイティブ（操作感・
   統合が最良、ただし WinZip AES 自前実装が必要）を比較し、**Swift/AppKit** を
   選択。暗号自前実装は相互検証フィクスチャで担保する条件付き
6. **命名**: zip-bridge / clean-zip / zip-porter から **zip-porter** を選択
7. **UX 詳細**: 作成は毎回オプションシート（設定でスキップ可）、展開は
   `.zip` 関連付けあり＋同階層展開、フェーズ分割はエンジン+CLI → GUI →
   リリースの 3 段階で確定

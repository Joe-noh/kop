# kop

## ビルド

```bash
goose build kop.goose && ./kop path/to/file.txt
```

```bash
goose kop.goose -- path/to/file.txt
```

## 構成

```
kop.goose          起動、メインループ
core/text.goose    piece table（元ファイルと追記バッファ、改行の索引）
core/select.goose  複数の選択範囲
core/undo.goose    undo/redo
core/edit.goose    全カーソルに効く編集コマンド
core/motion.goose  カーソル移動（文字・単語・行・上下）
core/utf8.goose    UTF-8 と文字種
core/width.goose   文字幅（セル数）
core/doc.goose     BOM・改行コード・インデントの検出と保存
core/settings.goose 設定ファイル（~/.kop/settings.json と、プロジェクトの .kop/settings.json）
core/syntax.goose  シンタックスハイライト（言語ごとの字句解析器への振り分け、行頭の状態のキャッシュ）
core/syntax/       字句解析器（code: Goose・Ruby・JS・TS、style: CSS・SCSS・Sass、markup: HTML）、言語の定義、共通部品
view/              描画、入力、フォント、ファイルツリー、テーマ、SDL まわり、テスト用の入力再生
```

## テスト

```bash
.tools/goose-v2026.3-macos-arm64/goose core_test.goose --debug
```

画面まわりは、ウィンドウなしで入力を再生して確かめられます（書式は `view/script.goose` の先頭に書いてあります）:

```bash
GOOSE_GFX_HEADLESS=1 ./kop file.txt --script script.txt --profile
```

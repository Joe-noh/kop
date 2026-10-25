# weigh

## ビルド

```bash
goose build weigh.goose && ./weigh path/to/file.txt
```

```bash
goose weigh.goose -- path/to/file.txt
```

## 構成

```
weigh.goose        起動、メインループ
core/text.goose    piece table（元ファイルと追記バッファ、改行の索引）
core/select.goose  複数の選択範囲
core/undo.goose    undo/redo
core/edit.goose    全カーソルに効く編集コマンド
core/motion.goose  カーソル移動（文字・単語・行・上下）
core/utf8.goose    UTF-8 と文字種
core/width.goose   文字幅（セル数）
core/doc.goose     BOM・改行コード・インデントの検出と保存
view/              描画、入力、フォント、SDL まわり、テスト用の入力再生
assets/            BIZ UDゴシック（SIL Open Font License）
```

## テスト

```bash
.tools/goose-v2026.3-macos-arm64/goose core_test.goose --debug
```

画面まわりは、ウィンドウなしで入力を再生して確かめられます（書式は `view/script.goose` の先頭に書いてあります）:

```bash
GOOSE_GFX_HEADLESS=1 ./weigh file.txt --script script.txt --profile
```

# kop

## ビルド

Zig 0.15.2（`mise install` で入る）と、SDL3・FreeType（`brew install sdl3 freetype`）が要る。

```bash
zig build run -- path/to/file.txt
```

```bash
zig build -Doptimize=ReleaseFast && zig-out/bin/kop path/to/dir
```

SDL3 と FreeType は既定で `/opt/homebrew` から探す。別の場所にあるときは `-Ddeps=<prefix>` で指定する。

## 構成

```
build.zig               ビルド、実行、テスト
src/main.zig            起動、ウィンドウ、文書ごとのメインループ
src/core/text.zig       piece table（元ファイルと追記バッファ、改行の索引）
src/core/select.zig     複数の選択範囲
src/core/undo.zig       undo/redo
src/core/edit.zig       全カーソルに効く編集コマンド
src/core/motion.zig     カーソル移動（文字・単語・行・上下）
src/core/utf8.zig       UTF-8 と文字種
src/core/width.zig      文字幅（セル数）
src/core/doc.zig        BOM・改行コード・インデントの検出と保存
src/core/settings.zig   設定ファイル（~/.kop/settings.json と、プロジェクトの .kop/settings.json）
src/core/keymap.zig     キーとコマンドの割り当て（既定値と、設定による上書き）
src/core/syntax.zig     シンタックスハイライト（字句解析器への振り分け、行頭の状態のキャッシュ）
src/core/syntax/        字句解析器（code: Zig・Goose・Ruby・JS・TS、style: CSS・SCSS・Sass、markup: HTML）、言語の定義、共通部品
src/view/               描画、入力、フォント（FreeType）、ファイルツリー、テーマ、SDL まわり、テスト用の入力再生
src/tests.zig           ウィンドウの要らないテストの入口
```

## テスト

```bash
zig build test
```

画面まわりは、隠したウィンドウで入力を再生して確かめられる（書式は `src/view/script.zig` の先頭にある）:

```bash
zig-out/bin/kop file.txt --script script.txt --profile
```

// The tests: those of every module that needs no window.

test {
    _ = @import("core/utf8.zig");
    _ = @import("core/width.zig");
    _ = @import("core/text.zig");
    _ = @import("core/select.zig");
    _ = @import("core/undo.zig");
    _ = @import("core/motion.zig");
    _ = @import("core/edit.zig");
    _ = @import("core/doc.zig");
    _ = @import("core/settings.zig");
    _ = @import("core/keymap.zig");
    _ = @import("core/syntax.zig");
    _ = @import("core/search.zig");
    _ = @import("core/git.zig");
    _ = @import("core/diff.zig");
    _ = @import("view/fontfile.zig");
    _ = @import("view/tree.zig");
}

// The C libraries: SDL3 for the window, input and drawing, FreeType for fonts.

pub const c = @cImport({
    @cInclude("SDL3/SDL.h");
    @cInclude("ft2build.h");
    @cInclude("freetype/freetype.h");
});

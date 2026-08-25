// This Source Code Form is subject to the terms of the Mozilla Public License,
// v. 2.0. If a copy of the MPL was not distributed with this file, You can
// obtain one at https://mozilla.org/MPL/2.0/.

//! Wire types shared by more than one format module.

/// Indexed color identifiers used for tracks and memory cues, stored as a
/// single byte: the pdb color rows and track `color` fields and the ANLZ
/// extended-cue entries reference them. Ported from rekordcrate's
/// `util::ColorIndex`.
pub const ColorIndex = enum(u8) {
    none = 0,
    pink = 1,
    red = 2,
    orange = 3,
    yellow = 4,
    green = 5,
    aqua = 6,
    blue = 7,
    purple = 8,
    _,
};

/// One of the eight fixed track colors a fresh export carries, shared by
/// the pdb color table and the OneLibrary `color` table: the row id, the
/// color it names, and its display name.
pub const ColorSpec = struct {
    id: u8,
    color: ColorIndex,
    name: []const u8,
};

/// The eight fixed track colors, in row order.
pub const color_specs = [_]ColorSpec{
    .{ .id = 1, .color = .pink, .name = "Pink" },
    .{ .id = 2, .color = .red, .name = "Red" },
    .{ .id = 3, .color = .orange, .name = "Orange" },
    .{ .id = 4, .color = .yellow, .name = "Yellow" },
    .{ .id = 5, .color = .green, .name = "Green" },
    .{ .id = 6, .color = .aqua, .name = "Aqua" },
    .{ .id = 7, .color = .blue, .name = "Blue" },
    .{ .id = 8, .color = .purple, .name = "Purple" },
};

/// One of the 27 metadata-category rows a fresh export carries in both the
/// pdb `columns` table and the OneLibrary `menuItem` table: the category
/// id shared by both, the kind constant both store for it (the pdb's
/// `unknown0`, the OL `kind`), and the display name wrapped in the Unicode
/// "interlinear annotation" anchors `\u{fffa}`/`\u{fffb}` — the anchors
/// force the long UCS-2LE string form even though the names are otherwise
/// ASCII.
pub const ColumnSpec = struct {
    id: u16,
    kind: u16,
    name: []const u8,
};

/// The 27 metadata categories, in row order.
pub const column_specs = [_]ColumnSpec{
    .{ .id = 1, .kind = 128, .name = "\u{FFFA}GENRE\u{FFFB}" },
    .{ .id = 2, .kind = 129, .name = "\u{FFFA}ARTIST\u{FFFB}" },
    .{ .id = 3, .kind = 130, .name = "\u{FFFA}ALBUM\u{FFFB}" },
    .{ .id = 4, .kind = 131, .name = "\u{FFFA}TRACK\u{FFFB}" },
    .{ .id = 5, .kind = 133, .name = "\u{FFFA}BPM\u{FFFB}" },
    .{ .id = 6, .kind = 134, .name = "\u{FFFA}RATING\u{FFFB}" },
    .{ .id = 7, .kind = 135, .name = "\u{FFFA}YEAR\u{FFFB}" },
    .{ .id = 8, .kind = 136, .name = "\u{FFFA}REMIXER\u{FFFB}" },
    .{ .id = 9, .kind = 137, .name = "\u{FFFA}LABEL\u{FFFB}" },
    .{ .id = 10, .kind = 138, .name = "\u{FFFA}ORIGINAL ARTIST\u{FFFB}" },
    .{ .id = 11, .kind = 139, .name = "\u{FFFA}KEY\u{FFFB}" },
    .{ .id = 12, .kind = 141, .name = "\u{FFFA}CUE\u{FFFB}" },
    .{ .id = 13, .kind = 142, .name = "\u{FFFA}COLOR\u{FFFB}" },
    .{ .id = 14, .kind = 146, .name = "\u{FFFA}TIME\u{FFFB}" },
    .{ .id = 15, .kind = 147, .name = "\u{FFFA}BITRATE\u{FFFB}" },
    .{ .id = 16, .kind = 148, .name = "\u{FFFA}FILE NAME\u{FFFB}" },
    .{ .id = 17, .kind = 132, .name = "\u{FFFA}PLAYLIST\u{FFFB}" },
    .{ .id = 18, .kind = 152, .name = "\u{FFFA}HOT CUE BANK\u{FFFB}" },
    .{ .id = 19, .kind = 149, .name = "\u{FFFA}HISTORY\u{FFFB}" },
    .{ .id = 20, .kind = 145, .name = "\u{FFFA}SEARCH\u{FFFB}" },
    .{ .id = 21, .kind = 150, .name = "\u{FFFA}COMMENTS\u{FFFB}" },
    .{ .id = 22, .kind = 140, .name = "\u{FFFA}DATE ADDED\u{FFFB}" },
    .{ .id = 23, .kind = 151, .name = "\u{FFFA}DJ PLAY COUNT\u{FFFB}" },
    .{ .id = 24, .kind = 144, .name = "\u{FFFA}FOLDER\u{FFFB}" },
    .{ .id = 25, .kind = 161, .name = "\u{FFFA}DEFAULT\u{FFFB}" },
    .{ .id = 26, .kind = 162, .name = "\u{FFFA}ALPHABET\u{FFFB}" },
    .{ .id = 27, .kind = 170, .name = "\u{FFFA}MATCHING\u{FFFB}" },
};

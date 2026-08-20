// This Source Code Form is subject to the terms of the Mozilla Public License,
// v. 2.0. If a copy of the MPL was not distributed with this file, You can
// obtain one at https://mozilla.org/MPL/2.0/.

//! Wire types shared by more than one format module.

/// Indexed color identifiers used for tracks and memory cues, stored as a
/// single byte: the pdb color rows and track `color` fields and the ANLZ
/// extended-cue entries reference them. Ported from rekordcrate's
/// `util::ColorIndex`.
pub const ColorIndex = enum(u8) {
    /// No color.
    none = 0,
    /// Pink color.
    pink = 1,
    /// Red color.
    red = 2,
    /// Orange color.
    orange = 3,
    /// Yellow color.
    yellow = 4,
    /// Green color.
    green = 5,
    /// Aqua color.
    aqua = 6,
    /// Blue color.
    blue = 7,
    /// Purple color.
    purple = 8,
    _,
};

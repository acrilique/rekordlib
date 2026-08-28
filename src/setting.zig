// This Source Code Form is subject to the terms of the Mozilla Public License,
// v. 2.0. If a copy of the MPL was not distributed with this file, You can
// obtain one at https://mozilla.org/MPL/2.0/.

//! Parser and writer for the Rekordbox settings files.
//!
//! The files are found in the `PIONEER` directory of a USB device export.
//!
//! Ported from rekordcrate's `src/setting.rs`.

const std = @import("std");
const bin = @import("bin.zig");

/// Size of the three NUL-padded string fields at the start of the file.
const string_field_len = 32;

/// Length of the three string fields, as recorded in the first header field
/// (`0x60` in all known files).
const len_string_fields = 3 * string_field_len;

/// Offset of the `data` section; the checksum starts at `data_offset + len_data`.
pub const data_offset = 4 + len_string_fields + 4;

pub const ParseError = error{ UnexpectedEof, InvalidFormat, UnexpectedValue, OutOfMemory, ChecksumMismatch };

/// Represents a `*SETTING.DAT` file, generic over the payload type `Data`
/// (`DevSetting` for `DEVSETTING.DAT`, `MySetting` for `MYSETTING.DAT`,
/// `MySetting2` for `MYSETTING2.DAT`, `DJMMySetting` for `DJMMYSETTING.DAT`).
/// The payload's fields are read and written in declaration order; its
/// serialized size determines the expected `len_data`, so parsing with a
/// payload type of a different size fails.
pub fn Setting(comptime Data: type) type {
    return struct {
        const Self = @This();

        /// Serialized size of the data section, derived from `Data`'s fields.
        const data_len = bin.serializedLen(Data);

        /// Name of the brand, NUL-padded ("PIONEER DJ" for `DEVSETTING.DAT`,
        /// "PIONEER" for `MYSETTING.DAT`).
        brand: [string_field_len]u8,
        /// Name of the software ("rekordbox"), NUL-padded.
        software: [string_field_len]u8,
        /// Some kind of version number ("6.6.1"), NUL-padded.
        version: [string_field_len]u8,
        /// The actual settings data.
        data: Data,
        /// Trailing unknown field, zero in all known files; parsing rejects any
        /// other value, so it is always zero in parsed instances.
        unknown: u16,

        /// Offset where the checksummed range begins, relative to the start
        /// of the setting: the data section, except in `DJMMYSETTING.DAT`
        /// where it covers the whole file.
        fn checksumOffset() usize {
            return if (Data.checksum_covers_data_only) data_offset else 0;
        }

        /// Parse a `*SETTING.DAT` image. The checksum is verified and a
        /// mismatch is reported as `error.ChecksumMismatch`; it is
        /// recalculated on write.
        pub fn parse(buf: []const u8) ParseError!Self {
            var c = bin.Cursor.init(buf);
            const len_stringdata = try c.takeInt(u32, .little);
            if (len_stringdata != len_string_fields) return error.InvalidFormat;
            const brand = (try c.takeArray(string_field_len)).*;
            const software = (try c.takeArray(string_field_len)).*;
            const version = (try c.takeArray(string_field_len)).*;
            const len_data = try c.takeInt(u32, .little);
            if (len_data != data_len) return error.InvalidFormat;
            const data = try bin.takeStruct(&c, Data, .little);
            try bin.validateConstantFields(Data, data);
            const checksum = try c.takeInt(u16, .little);
            const unknown = try c.takeInt(u16, .little);
            if (unknown != 0) return error.UnexpectedValue;
            if (!c.atEnd()) return error.InvalidFormat;
            const expected = std.hash.crc.Crc16Xmodem.hash(buf[checksumOffset() .. data_offset + data_len]);
            if (checksum != expected) return error.ChecksumMismatch;
            return .{
                .brand = brand,
                .software = software,
                .version = version,
                .data = data,
                .unknown = unknown,
            };
        }

        pub fn writeTo(s: *const Self, e: *bin.Emitter) bin.WriteError!void {
            const start = e.pos();
            try e.putInt(u32, len_string_fields, .little);
            try e.putBytes(&s.brand);
            try e.putBytes(&s.software);
            try e.putBytes(&s.version);
            try e.putInt(u32, data_len, .little);
            try bin.putStruct(e, &s.data, .little);
            const checksum_at = e.pos();
            try e.putInt(u16, 0, .little);
            try e.putInt(u16, s.unknown, .little);
            // The range is relative to where this setting starts in the
            // emitter, so appending to a non-empty emitter works too.
            const crc = std.hash.crc.Crc16Xmodem.hash(e.written()[start + checksumOffset() .. checksum_at]);
            e.patchIntAt(checksum_at, u16, crc, .little);
        }

        pub fn serialize(s: *const Self, alloc: std.mem.Allocator) bin.WriteError![]u8 {
            var e = bin.Emitter.init(alloc);
            defer e.deinit();
            try s.writeTo(&e);
            return e.toOwnedSlice();
        }

        /// Default values as found in Rekordbox 6.6.1.
        pub fn default() Self {
            return .{
                .brand = stringField(Data.default_brand),
                .software = stringField("rekordbox"),
                .version = stringField(Data.default_version),
                .data = .{},
                .unknown = 0,
            };
        }

        /// The brand string, without NUL padding (e.g. "PIONEER DJ").
        pub fn brandString(s: *const Self) []const u8 {
            return fieldString(&s.brand);
        }

        /// The software string, without NUL padding (e.g. "rekordbox").
        pub fn softwareString(s: *const Self) []const u8 {
            return fieldString(&s.software);
        }

        /// The version string, without NUL padding (e.g. "6.6.1").
        pub fn versionString(s: *const Self) []const u8 {
            return fieldString(&s.version);
        }
    };
}

/// Payload of a `DEVSETTING.DAT` file. Fields are read and written in
/// declaration order; the default values are those written by Rekordbox 6.6.1.
pub const DevSetting = struct {
    /// Unknown field, `78 56 34 12 01 00 00 00 01` in all known files.
    unknown1: [9]u8 = .{ 0x78, 0x56, 0x34, 0x12, 0x01, 0x00, 0x00, 0x00, 0x01 },
    /// "Type of the overview Waveform" setting.
    overview_waveform_type: OverviewWaveformType = .half_waveform,
    /// "Waveform color" setting.
    waveform_color: WaveformColor = .blue,
    /// Unknown field, `0x01` in all known files.
    unknown2: u8 = 0x01,
    /// "Key display format" setting.
    key_display_format: KeyDisplayFormat = .classic,
    /// "Waveform Current Position" setting.
    waveform_current_position: WaveformCurrentPosition = .center,
    /// Unknown field, zero in all known files.
    unknown3: [18]u8 = @splat(0),

    /// The checksum covers just the data section (see `Setting.writeTo`).
    pub const checksum_covers_data_only = true;

    /// Brand string found in `DEVSETTING.DAT` files written by Rekordbox.
    pub const default_brand = "PIONEER DJ";

    /// Version string found in `DEVSETTING.DAT` files written by Rekordbox.
    pub const default_version = "6.6.1";

    /// Fields that must hold their default value in all known files;
    /// other values are rejected on parse (see `bin.validateConstantFields`).
    pub const constant_fields = .{ .unknown1, .unknown2, .unknown3 };
};

/// Payload of a `MYSETTING.DAT` file. Fields are read and written in
/// declaration order; the default values are those written by Rekordbox 6.6.1.
pub const MySetting = struct {
    /// Unknown field (fixtures carry `78 56 34 12 02 00 00 00`), kept verbatim.
    unknown1: [8]u8 = .{ 0x78, 0x56, 0x34, 0x12, 0x02, 0x00, 0x00, 0x00 },
    /// "ON AIR DISPLAY" setting.
    on_air_display: OnAirDisplay = .on,
    /// "LCD BRIGHTNESS" setting.
    lcd_brightness: LcdBrightness = .three,
    /// "QUANTIZE" setting.
    quantize: Quantize = .on,
    /// "AUTO CUE LEVEL" setting.
    auto_cue_level: AutoCueLevel = .memory,
    /// "LANGUAGE" setting.
    language: Language = .english,
    /// Unknown field (apparently always `0x01`), kept verbatim.
    unknown2: u8 = 0x01,
    /// "JOG RING BRIGHTNESS" setting.
    jog_ring_brightness: JogRingBrightness = .bright,
    /// "JOG RING INDICATOR" setting.
    jog_ring_indicator: JogRingIndicator = .on,
    /// "SLIP FLASHING" setting.
    slip_flashing: SlipFlashing = .on,
    /// Unknown field (fixtures carry `01 01 01`), kept verbatim.
    unknown3: [3]u8 = .{ 0x01, 0x01, 0x01 },
    /// "DISC SLOT ILLUMINATION" setting.
    disc_slot_illumination: DiscSlotIllumination = .bright,
    /// "EJECT/LOAD LOCK" setting.
    eject_lock: EjectLock = .unlock,
    /// "SYNC" setting.
    sync: Sync = .off,
    /// "PLAY MODE / AUTO PLAY MODE" setting.
    play_mode: PlayMode = .single,
    /// "QUANTIZE BEAT VALUE" setting.
    quantize_beat_value: QuantizeBeatValue = .full_beat,
    /// "HOT CUE AUTO LOAD" setting.
    hotcue_autoload: HotCueAutoLoad = .on,
    /// "HOT CUE COLOR" setting.
    hotcue_color: HotCueColor = .off,
    /// Unknown field, zero in all known files.
    unknown4: u16 = 0,
    /// "NEEDLE LOCK" setting.
    needle_lock: NeedleLock = .lock,
    /// Unknown field, zero in all known files.
    unknown5: u16 = 0,
    /// "TIME MODE" setting.
    time_mode: TimeMode = .remain,
    /// "JOG MODE" setting.
    jog_mode: JogMode = .vinyl,
    /// "AUTO CUE" setting.
    auto_cue: AutoCue = .on,
    /// "MASTER TEMPO" setting.
    master_tempo: MasterTempo = .off,
    /// "TEMPO RANGE" setting.
    tempo_range: TempoRange = .ten_percent,
    /// "PHASE METER" setting.
    phase_meter: PhaseMeter = .type1,
    /// Unknown field, zero in all known files.
    unknown6: u16 = 0,

    /// The checksum covers just the data section (see `Setting.writeTo`).
    pub const checksum_covers_data_only = true;

    /// Brand string found in `MYSETTING.DAT` files written by Rekordbox.
    pub const default_brand = "PIONEER";

    /// Version string found in `MYSETTING.DAT` files written by Rekordbox 6.6.1.
    pub const default_version = "0.001";

    /// Fields that must hold their default value in all known files;
    /// other values are rejected on parse (see `bin.validateConstantFields`).
    pub const constant_fields = .{ .unknown4, .unknown5, .unknown6 };
};

/// Payload of a `MYSETTING2.DAT` file. Fields are read and written in
/// declaration order; the default values are those written by Rekordbox 6.6.1.
pub const MySetting2 = struct {
    /// "VINYL SPEED ADJUST" setting.
    vinyl_speed_adjust: VinylSpeedAdjust = .touch,
    /// "JOG DISPLAY MODE" setting.
    jog_display_mode: JogDisplayMode = .auto,
    /// "PAD/BUTTON BRIGHTNESS" setting.
    pad_button_brightness: PadButtonBrightness = .three,
    /// "JOG LCD BRIGHTNESS" setting.
    jog_lcd_brightness: JogLcdBrightness = .three,
    /// "WAVEFORM DIVISIONS" setting.
    waveform_divisions: WaveformDivisions = .phrase,
    /// Unknown field, zero in all known files.
    unknown1: [5]u8 = @splat(0),
    /// "WAVEFORM / PHASE METER" setting.
    waveform: Waveform = .waveform,
    /// Unknown field (apparently always `0x81`), kept verbatim.
    unknown2: u8 = 0x81,
    /// "BEAT JUMP BEAT VALUE" setting.
    beat_jump_beat_value: BeatJumpBeatValue = .sixteen_beat,
    /// Unknown field, zero in all known files.
    unknown3: [27]u8 = @splat(0),

    /// The checksum covers just the data section (see `Setting.writeTo`).
    pub const checksum_covers_data_only = true;

    /// Brand string found in `MYSETTING2.DAT` files written by Rekordbox.
    pub const default_brand = "PIONEER";

    /// Version string found in `MYSETTING2.DAT` files written by Rekordbox 6.6.1.
    pub const default_version = "0.001";

    /// Fields that must hold their default value in all known files;
    /// other values are rejected on parse (see `bin.validateConstantFields`).
    pub const constant_fields = .{ .unknown1, .unknown3 };
};

/// Payload of a `DJMMYSETTING.DAT` file. Fields are read and written in
/// declaration order; the default values are those written by Rekordbox 6.6.1.
pub const DJMMySetting = struct {
    /// Unknown field (fixtures carry `78 56 34 12 01 00 00 00 20 00 00 00`),
    /// kept verbatim.
    unknown1: [12]u8 = .{ 0x78, 0x56, 0x34, 0x12, 0x01, 0x00, 0x00, 0x00, 0x20, 0x00, 0x00, 0x00 },
    /// "CH FADER CURVE" setting.
    channel_fader_curve: ChannelFaderCurve = .linear,
    /// "CROSSFADER CURVE" setting.
    crossfader_curve: CrossfaderCurve = .fast_cut,
    /// "HEADPHONES PRE EQ" setting.
    headphones_pre_eq: HeadphonesPreEq = .post_eq,
    /// "HEADPHONES MONO SPLIT" setting.
    headphones_mono_split: HeadphonesMonoSplit = .stereo,
    /// "BEAT FX QUANTIZE" setting.
    beat_fx_quantize: BeatFxQuantize = .on,
    /// "MIC LOW CUT" setting.
    mic_low_cut: MicLowCut = .on,
    /// "TALK OVER MODE" setting.
    talk_over_mode: TalkOverMode = .advanced,
    /// "TALK OVER LEVEL" setting.
    talk_over_level: TalkOverLevel = .minus_18_db,
    /// "MIDI CH" setting.
    midi_channel: MidiChannel = .one,
    /// "MIDI BUTTON TYPE" setting.
    midi_button_type: MidiButtonType = .toggle,
    /// "BRIGHTNESS > DISPLAY" setting.
    display_brightness: MixerDisplayBrightness = .five,
    /// "BRIGHTNESS > INDICATOR" setting.
    indicator_brightness: MixerIndicatorBrightness = .three,
    /// "CH FADER CURVE (LONG FADER)" setting.
    channel_fader_curve_long_fader: ChannelFaderCurveLongFader = .exponential,
    /// Unknown field, zero in older files; newer exports carry five
    /// setting-like bytes (`0x80`-range values, not yet modeled) at its
    /// start. Kept verbatim.
    unknown2: [27]u8 = @splat(0),

    /// Unlike the other settings files, the checksum covers the whole file
    /// (see `Setting.writeTo`).
    pub const checksum_covers_data_only = false;

    /// Brand string found in `DJMMYSETTING.DAT` files written by Rekordbox.
    pub const default_brand = "PioneerDJ";

    /// Version string found in `DJMMYSETTING.DAT` files written by Rekordbox 6.6.1.
    pub const default_version = "1.000";
};

/// "Type of the overview Waveform" setting. Found on the "General" page in the
/// Rekordbox preferences.
pub const OverviewWaveformType = enum(u8) {
    /// "Half Waveform"
    half_waveform = 0x01,
    /// "Full Waveform"
    full_waveform = 0x02,
    _,
};

/// "Waveform color" setting. Found on the "General" page in the Rekordbox
/// preferences.
pub const WaveformColor = enum(u8) {
    /// "BLUE"
    blue = 0x01,
    /// "RGB"
    rgb = 0x03,
    /// "3Band"
    tri_band = 0x04,
    _,
};

/// "Key display format" setting. Found on the "General" page in the Rekordbox
/// preferences.
pub const KeyDisplayFormat = enum(u8) {
    /// "Classic"
    classic = 0x01,
    /// "Alphanumeric"
    alphanumeric = 0x02,
    _,
};

/// "Waveform Current Position" setting. Found on the "General" page in the
/// Rekordbox preferences.
pub const WaveformCurrentPosition = enum(u8) {
    /// "CENTER"
    center = 0x01,
    /// "LEFT"
    left = 0x02,
    _,
};

/// "ON AIR DISPLAY" setting. Found at "PLAYER > DISPLAY (INDICATOR)" on the
/// "My Settings" page in the Rekordbox preferences.
pub const OnAirDisplay = enum(u8) {
    /// "OFF"
    off = 0x80,
    /// "ON"
    on = 0x81,
    _,
};

/// "LCD BRIGHTNESS" setting. Found at "PLAYER > DISPLAY (LCD)" on the "My
/// Settings" page in the Rekordbox preferences.
pub const LcdBrightness = enum(u8) {
    /// "1"
    one = 0x81,
    /// "2"
    two = 0x82,
    /// "3"
    three = 0x83,
    /// "4"
    four = 0x84,
    /// "5"
    five = 0x85,
    _,
};

/// "QUANTIZE" setting. Found at "PLAYER > DJ SETTING" on the "My Settings"
/// page in the Rekordbox preferences.
pub const Quantize = enum(u8) {
    /// "OFF"
    off = 0x80,
    /// "ON"
    on = 0x81,
    _,
};

/// "AUTO CUE LEVEL" setting. Found at "PLAYER > DJ SETTING" on the "My
/// Settings" page in the Rekordbox preferences.
pub const AutoCueLevel = enum(u8) {
    /// "-78dB"
    minus_78_db = 0x87,
    /// "-72dB"
    minus_72_db = 0x86,
    /// "-66dB"
    minus_66_db = 0x85,
    /// "-60dB"
    minus_60_db = 0x84,
    /// "-54dB"
    minus_54_db = 0x83,
    /// "-48dB"
    minus_48_db = 0x82,
    /// "-42dB"
    minus_42_db = 0x81,
    /// "-36dB"
    minus_36_db = 0x80,
    /// "MEMORY"
    memory = 0x88,
    _,
};

/// "LANGUAGE" setting. Found at "PLAYER > DISPLAY (LCD)" on the "My Settings"
/// page in the Rekordbox preferences.
pub const Language = enum(u8) {
    /// "English"
    english = 0x81,
    /// "Français"
    french = 0x82,
    /// "Deutsch"
    german = 0x83,
    /// "Italiano"
    italian = 0x84,
    /// "Nederlands"
    dutch = 0x85,
    /// "Español"
    spanish = 0x86,
    /// "Русский"
    russian = 0x87,
    /// "한국어"
    korean = 0x88,
    /// "简体中文"
    chinese_simplified = 0x89,
    /// "繁體中文"
    chinese_traditional = 0x8A,
    /// "日本語"
    japanese = 0x8B,
    /// "Português"
    portuguese = 0x8C,
    /// "Svenska"
    swedish = 0x8D,
    /// "Čeština"
    czech = 0x8E,
    /// "Magyar"
    hungarian = 0x8F,
    /// "Dansk"
    danish = 0x90,
    /// "Ελληνικά"
    greek = 0x91,
    /// "Türkçe"
    turkish = 0x92,
    _,
};

/// "JOG RING BRIGHTNESS" setting. Found at "PLAYER > DISPLAY (INDICATOR)" on
/// the "My Settings" page in the Rekordbox preferences.
pub const JogRingBrightness = enum(u8) {
    /// "OFF"
    off = 0x80,
    /// "1 (Dark)"
    dark = 0x81,
    /// "2 (Bright)"
    bright = 0x82,
    _,
};

/// "JOG RING INDICATOR" setting. Found at "PLAYER > DISPLAY (INDICATOR)" on
/// the "My Settings" page in the Rekordbox preferences.
pub const JogRingIndicator = enum(u8) {
    /// "OFF"
    off = 0x80,
    /// "ON"
    on = 0x81,
    _,
};

/// "SLIP FLASHING" setting. Found at "PLAYER > DISPLAY (INDICATOR)" on the
/// "My Settings" page in the Rekordbox preferences.
pub const SlipFlashing = enum(u8) {
    /// "OFF"
    off = 0x80,
    /// "ON"
    on = 0x81,
    _,
};

/// "DISC SLOT ILLUMINATION" setting. Found at "PLAYER > DISPLAY (INDICATOR)"
/// on the "My Settings" page in the Rekordbox preferences.
pub const DiscSlotIllumination = enum(u8) {
    /// "OFF"
    off = 0x80,
    /// "1 (Dark)"
    dark = 0x81,
    /// "2 (Bright)"
    bright = 0x82,
    _,
};

/// "EJECT/LOAD LOCK" setting. Found at "PLAYER > DJ SETTING" on the "My
/// Settings" page in the Rekordbox preferences.
pub const EjectLock = enum(u8) {
    /// "UNLOCK"
    unlock = 0x80,
    /// "LOCK"
    lock = 0x81,
    _,
};

/// "SYNC" setting. Found at "PLAYER > DJ SETTING" on the "My Settings" page in
/// the Rekordbox preferences.
pub const Sync = enum(u8) {
    /// "OFF"
    off = 0x80,
    /// "ON"
    on = 0x81,
    _,
};

/// "PLAY MODE / AUTO PLAY MODE" setting. Found at "PLAYER > DJ SETTING" on the
/// "My Settings" page in the Rekordbox preferences.
pub const PlayMode = enum(u8) {
    /// "CONTINUE / ON"
    continue_mode = 0x80,
    /// "SINGLE / OFF"
    single = 0x81,
    _,
};

/// "QUANTIZE BEAT VALUE" setting. Found at "PLAYER > DJ SETTING" on the "My
/// Settings" page in the Rekordbox preferences.
pub const QuantizeBeatValue = enum(u8) {
    /// "1/8 Beat"
    eighth_beat = 0x83,
    /// "1/4 Beat"
    quarter_beat = 0x82,
    /// "1/2 Beat"
    half_beat = 0x81,
    /// "1 Beat"
    full_beat = 0x80,
    _,
};

/// "HOT CUE AUTO LOAD" setting. Found at "PLAYER > DJ SETTING" on the "My
/// Settings" page in the Rekordbox preferences.
pub const HotCueAutoLoad = enum(u8) {
    /// "OFF"
    off = 0x80,
    /// "On"
    on = 0x81,
    /// "rekordbox SETTING"
    rekordbox_setting = 0x82,
    _,
};

/// "HOT CUE COLOR" setting. Found at "PLAYER > DJ SETTING" on the "My
/// Settings" page in the Rekordbox preferences.
pub const HotCueColor = enum(u8) {
    /// "OFF"
    off = 0x80,
    /// "On"
    on = 0x81,
    _,
};

/// "NEEDLE LOCK" setting. Found at "PLAYER > DJ SETTING" on the "My Settings"
/// page in the Rekordbox preferences.
pub const NeedleLock = enum(u8) {
    /// "UNLOCK"
    unlock = 0x80,
    /// "LOCK"
    lock = 0x81,
    _,
};

/// "TIME MODE" setting. Found at "PLAYER > DJ SETTING" on the "My Settings"
/// page in the Rekordbox preferences.
pub const TimeMode = enum(u8) {
    /// "Elapsed"
    elapsed = 0x80,
    /// "REMAIN"
    remain = 0x81,
    _,
};

/// "JOG MODE" setting. Found at "PLAYER > DJ SETTING" on the "My Settings"
/// page in the Rekordbox preferences.
pub const JogMode = enum(u8) {
    /// "VINYL"
    vinyl = 0x81,
    /// "CDJ"
    cdj = 0x80,
    _,
};

/// "AUTO CUE" setting. Found at "PLAYER > DJ SETTING" on the "My Settings"
/// page in the Rekordbox preferences.
pub const AutoCue = enum(u8) {
    /// "OFF"
    off = 0x80,
    /// "ON"
    on = 0x81,
    _,
};

/// "MASTER TEMPO" setting. Found at "PLAYER > DJ SETTING" on the "My Settings"
/// page in the Rekordbox preferences.
pub const MasterTempo = enum(u8) {
    /// "OFF"
    off = 0x80,
    /// "ON"
    on = 0x81,
    _,
};

/// "TEMPO RANGE" setting. Found at "PLAYER > DJ SETTING" on the "My Settings"
/// page in the Rekordbox preferences.
pub const TempoRange = enum(u8) {
    /// "±6%"
    six_percent = 0x80,
    /// "±10%"
    ten_percent = 0x81,
    /// "±16%"
    sixteen_percent = 0x82,
    /// "WIDE"
    wide = 0x83,
    _,
};

/// "PHASE METER" setting. Found at "PLAYER > DJ SETTING" on the "My Settings"
/// page in the Rekordbox preferences.
pub const PhaseMeter = enum(u8) {
    /// "TYPE 1"
    type1 = 0x80,
    /// "TYPE 2"
    type2 = 0x81,
    _,
};

/// "WAVEFORM / PHASE METER" setting. Found at "PLAYER > DJ SETTING" on the
/// "My Settings" page in the Rekordbox preferences.
pub const Waveform = enum(u8) {
    /// "WAVEFORM"
    waveform = 0x80,
    /// "PHASE METER"
    phase_meter = 0x81,
    _,
};

/// "WAVEFORM DIVISIONS" setting. Found at "PLAYER > DJ SETTING" on the "My
/// Settings" page in the Rekordbox preferences.
pub const WaveformDivisions = enum(u8) {
    /// "TIME SCALE"
    time_scale = 0x80,
    /// "PHRASE"
    phrase = 0x81,
    _,
};

/// "VINYL SPEED ADJUST" setting. Found at "PLAYER > DJ SETTING" on the "My
/// Settings" page in the Rekordbox preferences.
pub const VinylSpeedAdjust = enum(u8) {
    /// "TOUCH & RELEASE"
    touch_release = 0x80,
    /// "TOUCH"
    touch = 0x81,
    /// "RELEASE"
    release = 0x82,
    _,
};

/// "BEAT JUMP BEAT VALUE" setting. Found at "PLAYER > DJ SETTING" on the "My
/// Settings" page in the Rekordbox preferences.
pub const BeatJumpBeatValue = enum(u8) {
    /// "1/2 BEAT"
    half_beat = 0x80,
    /// "1 BEAT"
    one_beat = 0x81,
    /// "2 BEAT"
    two_beat = 0x82,
    /// "4 BEAT"
    four_beat = 0x83,
    /// "8 BEAT"
    eight_beat = 0x84,
    /// "16 BEAT"
    sixteen_beat = 0x85,
    /// "32 BEAT"
    thirtytwo_beat = 0x86,
    /// "64 BEAT"
    sixtyfour_beat = 0x87,
    _,
};

/// "JOG DISPLAY MODE" setting. Found at "PLAYER > DISPLAY (LCD)" on the "My
/// Settings" page in the Rekordbox preferences.
pub const JogDisplayMode = enum(u8) {
    /// "AUTO"
    auto = 0x80,
    /// "INFO"
    info = 0x81,
    /// "SIMPLE"
    simple = 0x82,
    /// "ARTWORK"
    artwork = 0x83,
    _,
};

/// "JOG LCD BRIGHTNESS" setting. Found at "PLAYER > DISPLAY (LCD)" on the "My
/// Settings" page in the Rekordbox preferences.
pub const JogLcdBrightness = enum(u8) {
    /// "1"
    one = 0x81,
    /// "2"
    two = 0x82,
    /// "3"
    three = 0x83,
    /// "4"
    four = 0x84,
    /// "5"
    five = 0x85,
    _,
};

/// "PAD/BUTTON BRIGHTNESS" setting. Found at "PLAYER > DISPLAY (INDICATOR)" on
/// the "My Settings" page in the Rekordbox preferences.
pub const PadButtonBrightness = enum(u8) {
    /// "1"
    one = 0x81,
    /// "2"
    two = 0x82,
    /// "3"
    three = 0x83,
    /// "4"
    four = 0x84,
    _,
};

/// "CH FADER CURVE" setting. Found at "MIXER > DJ SETTING" on the "My
/// Settings" page in the Rekordbox preferences.
pub const ChannelFaderCurve = enum(u8) {
    /// Steep volume raise when the fader is moved near the top.
    steep_top = 0x80,
    /// Linear volume raise when the fader is moved.
    linear = 0x81,
    /// Steep volume raise when the fader is moved near the bottom.
    steep_bottom = 0x82,
    _,
};

/// "CROSSFADER CURVE" setting. Found at "MIXER > DJ SETTING" on the "My
/// Settings" page in the Rekordbox preferences.
pub const CrossfaderCurve = enum(u8) {
    /// Logarithmic volume raise of the other channel near the edges of the
    /// fader.
    constant_power = 0x80,
    /// Slow steep linear volume raise of the other channel near the edges of
    /// the fader.
    slow_cut = 0x81,
    /// Fast steep linear volume raise of the other channel near the edges of
    /// the fader.
    fast_cut = 0x82,
    _,
};

/// "CH FADER CURVE (LONG FADER)" setting. Found at "MIXER > DJ SETTING" on the
/// "My Settings" page in the Rekordbox preferences.
pub const ChannelFaderCurveLongFader = enum(u8) {
    /// Very steep volume raise when the fader is moved near the top (e.g.
    /// y = x⁵).
    exponential = 0x80,
    /// Steep volume raise when the fader is moved near the top (e.g. y = x²).
    smooth = 0x81,
    /// Linear volume raise when the fader is moved (e.g. y = k * x).
    linear = 0x82,
    _,
};

/// "HEADPHONES PRE EQ" setting. Found at "MIXER > DJ SETTING" on the "My
/// Settings" page in the Rekordbox preferences.
pub const HeadphonesPreEq = enum(u8) {
    /// "POST EQ"
    post_eq = 0x80,
    /// "PRE EQ"
    pre_eq = 0x81,
    _,
};

/// "HEADPHONES MONO SPLIT" setting. Found at "MIXER > DJ SETTING" on the "My
/// Settings" page in the Rekordbox preferences.
pub const HeadphonesMonoSplit = enum(u8) {
    /// "STEREO"
    stereo = 0x80,
    /// "MONO SPLIT"
    mono_split = 0x81,
    _,
};

/// "BEAT FX QUANTIZE" setting. Found at "MIXER > DJ SETTING" on the "My
/// Settings" page in the Rekordbox preferences.
pub const BeatFxQuantize = enum(u8) {
    /// "OFF"
    off = 0x80,
    /// "ON"
    on = 0x81,
    _,
};

/// "MIC LOW CUT" setting. Found at "MIXER > DJ SETTING" on the "My Settings"
/// page in the Rekordbox preferences.
pub const MicLowCut = enum(u8) {
    /// "OFF"
    off = 0x80,
    /// "ON (for MC)"
    on = 0x81,
    _,
};

/// "TALK OVER MODE" setting. Found at "MIXER > DJ SETTING" on the "My
/// Settings" page in the Rekordbox preferences.
pub const TalkOverMode = enum(u8) {
    /// "ADVANCED"
    advanced = 0x80,
    /// "NORMAL"
    normal = 0x81,
    _,
};

/// "TALK OVER LEVEL" setting. Found at "MIXER > DJ SETTING" on the "My
/// Settings" page in the Rekordbox preferences.
pub const TalkOverLevel = enum(u8) {
    /// "-24dB"
    minus_24_db = 0x80,
    /// "-18dB"
    minus_18_db = 0x81,
    /// "-12dB"
    minus_12_db = 0x82,
    /// "-6dB"
    minus_6_db = 0x83,
    _,
};

/// "MIDI CH" setting. Found at "MIXER > DJ SETTING" on the "My Settings" page
/// in the Rekordbox preferences.
pub const MidiChannel = enum(u8) {
    /// "1"
    one = 0x80,
    /// "2"
    two = 0x81,
    /// "3"
    three = 0x82,
    /// "4"
    four = 0x83,
    /// "5"
    five = 0x84,
    /// "6"
    six = 0x85,
    /// "7"
    seven = 0x86,
    /// "8"
    eight = 0x87,
    /// "9"
    nine = 0x88,
    /// "10"
    ten = 0x89,
    /// "11"
    eleven = 0x8A,
    /// "12"
    twelve = 0x8B,
    /// "13"
    thirteen = 0x8C,
    /// "14"
    fourteen = 0x8D,
    /// "15"
    fifteen = 0x8E,
    /// "16"
    sixteen = 0x8F,
    _,
};

/// "MIDI BUTTON TYPE" setting. Found at "MIXER > DJ SETTING" on the "My
/// Settings" page in the Rekordbox preferences.
pub const MidiButtonType = enum(u8) {
    /// "TOGGLE"
    toggle = 0x80,
    /// "TRIGGER"
    trigger = 0x81,
    _,
};

/// "BRIGHTNESS > DISPLAY" setting. Found at "MIXER > BRIGHTNESS" on the "My
/// Settings" page in the Rekordbox preferences.
pub const MixerDisplayBrightness = enum(u8) {
    /// "WHITE"
    white = 0x80,
    /// "1"
    one = 0x81,
    /// "2"
    two = 0x82,
    /// "3"
    three = 0x83,
    /// "4"
    four = 0x84,
    /// "5"
    five = 0x85,
    _,
};

/// "BRIGHTNESS > INDICATOR" setting. Found at "MIXER > BRIGHTNESS" on the "My
/// Settings" page in the Rekordbox preferences.
pub const MixerIndicatorBrightness = enum(u8) {
    /// "1"
    one = 0x80,
    /// "2"
    two = 0x81,
    /// "3"
    three = 0x82,
    _,
};

fn stringField(comptime s: []const u8) [string_field_len]u8 {
    comptime std.debug.assert(s.len < string_field_len);
    var field = [_]u8{0} ** string_field_len;
    @memcpy(field[0..s.len], s);
    return field;
}

fn fieldString(field: []const u8) []const u8 {
    const end = std.mem.indexOfScalar(u8, field, 0) orelse field.len;
    return field[0..end];
}

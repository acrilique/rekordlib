// This Source Code Form is subject to the terms of the Mozilla Public License,
// v. 2.0. If a copy of the MPL was not distributed with this file, You can
// obtain one at https://mozilla.org/MPL/2.0/.

//! Parser and writer for the Rekordbox settings files.
//!
//! The files are found in the `PIONEER` directory of a USB device export.
//!
//! Ported from rekordcrate's `src/setting.rs`
//!
//!
//! Unknown fields and unknown enum values are stored on parse and written back
//! verbatim, so a parsed file always re-serializes byte-identically.

const std = @import("std");
const bin = @import("bin");

/// Size of the three NUL-padded string fields at the start of the file.
const string_field_len = 32;

/// Offset of the `data` section; the checksum starts at `data_offset + len_data`.
const data_offset = 4 + 3 * string_field_len + 4;

pub const ParseError = error{ UnexpectedEof, InvalidFormat };

/// Represents a `*SETTING.DAT` file, generic over the payload type `Data`
/// (`DevSetting` for `DEVSETTING.DAT`, `MySetting` for `MYSETTING.DAT`,
/// `MySetting2` for `MYSETTING2.DAT`, `DJMMySetting` for `DJMMYSETTING.DAT`).
/// The payload type determines the expected `len_data`, so parsing with a
/// payload type of a different size fails.
pub fn Setting(comptime Data: type) type {
    return struct {
        const Self = @This();

        /// Name of the brand, NUL-padded ("PIONEER DJ" for `DEVSETTING.DAT`,
        /// "PIONEER" for `MYSETTING.DAT`).
        brand: [string_field_len]u8,
        /// Name of the software ("rekordbox"), NUL-padded.
        software: [string_field_len]u8,
        /// Some kind of version number ("6.6.1"), NUL-padded.
        version: [string_field_len]u8,
        /// The actual settings data.
        data: Data,
        /// Trailing unknown field (apparently always zero), kept verbatim.
        unknown: u16,

        /// Parse a `*SETTING.DAT` image. The checksum is not verified; it is
        /// recalculated on write.
        pub fn parse(buf: []const u8) ParseError!Self {
            var c = bin.Cursor.init(buf);
            const len_stringdata = try c.takeInt(u32);
            if (len_stringdata != 0x60) return error.InvalidFormat;
            const brand = (try c.takeArray(string_field_len)).*;
            const software = (try c.takeArray(string_field_len)).*;
            const version = (try c.takeArray(string_field_len)).*;
            const len_data = try c.takeInt(u32);
            if (len_data != Data.serialized_len) return error.InvalidFormat;
            const data = try Data.parse(&c);
            _ = try c.takeInt(u16);
            const unknown = try c.takeInt(u16);
            if (!c.atEnd()) return error.InvalidFormat;
            return .{
                .brand = brand,
                .software = software,
                .version = version,
                .data = data,
                .unknown = unknown,
            };
        }

        pub fn writeTo(s: *const Self, e: *bin.Emitter) bin.WriteError!void {
            try e.putInt(u32, 0x60);
            try e.putBytes(&s.brand);
            try e.putBytes(&s.software);
            try e.putBytes(&s.version);
            try e.putInt(u32, Data.serialized_len);
            try s.data.writeTo(e);
            const checksum_at = e.pos();
            try e.putInt(u16, 0);
            try e.putInt(u16, s.unknown);
            // The checksum covers just the data section, except in
            // `DJMMYSETTING.DAT` where it covers the whole file.
            const checksum_start = if (Data.checksum_covers_data_only) data_offset else 0;
            const crc = crc16Xmodem(e.written()[checksum_start..checksum_at]);
            e.patchIntAt(checksum_at, u16, crc);
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
                .data = Data.default(),
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

/// Payload of a `DEVSETTING.DAT` file.
pub const DevSetting = struct {
    /// Unknown field (fixtures carry `78 56 34 12 01 00 00 00 01`), kept
    /// verbatim.
    unknown1: [9]u8,
    /// "Type of the overview Waveform" setting.
    overview_waveform_type: OverviewWaveformType,
    /// "Waveform color" setting.
    waveform_color: WaveformColor,
    /// Unknown field (apparently always `0x01`), kept verbatim.
    unknown2: u8,
    /// "Key display format" setting.
    key_display_format: KeyDisplayFormat,
    /// "Waveform Current Position" setting.
    waveform_current_position: WaveformCurrentPosition,
    /// Unknown field (apparently always zero), kept verbatim.
    unknown3: [18]u8,

    pub const serialized_len = 32;

    /// The checksum covers just the data section (see `Setting.writeTo`).
    pub const checksum_covers_data_only = true;

    /// Brand string found in `DEVSETTING.DAT` files written by Rekordbox.
    pub const default_brand = "PIONEER DJ";

    /// Version string found in `DEVSETTING.DAT` files written by Rekordbox.
    pub const default_version = "6.6.1";

    pub fn parse(c: *bin.Cursor) bin.ReadError!DevSetting {
        return .{
            .unknown1 = (try c.takeArray(9)).*,
            .overview_waveform_type = @enumFromInt(try c.takeInt(u8)),
            .waveform_color = @enumFromInt(try c.takeInt(u8)),
            .unknown2 = try c.takeInt(u8),
            .key_display_format = @enumFromInt(try c.takeInt(u8)),
            .waveform_current_position = @enumFromInt(try c.takeInt(u8)),
            .unknown3 = (try c.takeArray(18)).*,
        };
    }

    pub fn writeTo(d: *const DevSetting, e: *bin.Emitter) bin.WriteError!void {
        try e.putBytes(&d.unknown1);
        try e.putInt(u8, @intFromEnum(d.overview_waveform_type));
        try e.putInt(u8, @intFromEnum(d.waveform_color));
        try e.putInt(u8, d.unknown2);
        try e.putInt(u8, @intFromEnum(d.key_display_format));
        try e.putInt(u8, @intFromEnum(d.waveform_current_position));
        try e.putBytes(&d.unknown3);
    }

    /// Default values as found in Rekordbox 6.6.1.
    pub fn default() DevSetting {
        return .{
            .unknown1 = .{ 0x78, 0x56, 0x34, 0x12, 0x01, 0x00, 0x00, 0x00, 0x01 },
            .overview_waveform_type = .half_waveform,
            .waveform_color = .blue,
            .unknown2 = 0x01,
            .key_display_format = .classic,
            .waveform_current_position = .center,
            .unknown3 = @splat(0),
        };
    }
};

/// Payload of a `MYSETTING.DAT` file.
pub const MySetting = struct {
    /// Unknown field (fixtures carry `78 56 34 12 02 00 00 00`), kept verbatim.
    unknown1: [8]u8,
    /// "ON AIR DISPLAY" setting.
    on_air_display: OnAirDisplay,
    /// "LCD BRIGHTNESS" setting.
    lcd_brightness: LcdBrightness,
    /// "QUANTIZE" setting.
    quantize: Quantize,
    /// "AUTO CUE LEVEL" setting.
    auto_cue_level: AutoCueLevel,
    /// "LANGUAGE" setting.
    language: Language,
    /// Unknown field (apparently always `0x01`), kept verbatim.
    unknown2: u8,
    /// "JOG RING BRIGHTNESS" setting.
    jog_ring_brightness: JogRingBrightness,
    /// "JOG RING INDICATOR" setting.
    jog_ring_indicator: JogRingIndicator,
    /// "SLIP FLASHING" setting.
    slip_flashing: SlipFlashing,
    /// Unknown field (fixtures carry `01 01 01`), kept verbatim.
    unknown3: [3]u8,
    /// "DISC SLOT ILLUMINATION" setting.
    disc_slot_illumination: DiscSlotIllumination,
    /// "EJECT/LOAD LOCK" setting.
    eject_lock: EjectLock,
    /// "SYNC" setting.
    sync: Sync,
    /// "PLAY MODE / AUTO PLAY MODE" setting.
    play_mode: PlayMode,
    /// "QUANTIZE BEAT VALUE" setting.
    quantize_beat_value: QuantizeBeatValue,
    /// "HOT CUE AUTO LOAD" setting.
    hotcue_autoload: HotCueAutoLoad,
    /// "HOT CUE COLOR" setting.
    hotcue_color: HotCueColor,
    /// Unknown field (apparently always zero), kept verbatim.
    unknown4: u16,
    /// "NEEDLE LOCK" setting.
    needle_lock: NeedleLock,
    /// Unknown field (apparently always zero), kept verbatim.
    unknown5: u16,
    /// "TIME MODE" setting.
    time_mode: TimeMode,
    /// "JOG MODE" setting.
    jog_mode: JogMode,
    /// "AUTO CUE" setting.
    auto_cue: AutoCue,
    /// "MASTER TEMPO" setting.
    master_tempo: MasterTempo,
    /// "TEMPO RANGE" setting.
    tempo_range: TempoRange,
    /// "PHASE METER" setting.
    phase_meter: PhaseMeter,
    /// Unknown field (apparently always zero), kept verbatim.
    unknown6: u16,

    pub const serialized_len = 40;

    /// The checksum covers just the data section (see `Setting.writeTo`).
    pub const checksum_covers_data_only = true;

    /// Brand string found in `MYSETTING.DAT` files written by Rekordbox.
    pub const default_brand = "PIONEER";

    /// Version string found in `MYSETTING.DAT` files written by Rekordbox 6.6.1.
    pub const default_version = "0.001";

    pub fn parse(c: *bin.Cursor) bin.ReadError!MySetting {
        return .{
            .unknown1 = (try c.takeArray(8)).*,
            .on_air_display = @enumFromInt(try c.takeInt(u8)),
            .lcd_brightness = @enumFromInt(try c.takeInt(u8)),
            .quantize = @enumFromInt(try c.takeInt(u8)),
            .auto_cue_level = @enumFromInt(try c.takeInt(u8)),
            .language = @enumFromInt(try c.takeInt(u8)),
            .unknown2 = try c.takeInt(u8),
            .jog_ring_brightness = @enumFromInt(try c.takeInt(u8)),
            .jog_ring_indicator = @enumFromInt(try c.takeInt(u8)),
            .slip_flashing = @enumFromInt(try c.takeInt(u8)),
            .unknown3 = (try c.takeArray(3)).*,
            .disc_slot_illumination = @enumFromInt(try c.takeInt(u8)),
            .eject_lock = @enumFromInt(try c.takeInt(u8)),
            .sync = @enumFromInt(try c.takeInt(u8)),
            .play_mode = @enumFromInt(try c.takeInt(u8)),
            .quantize_beat_value = @enumFromInt(try c.takeInt(u8)),
            .hotcue_autoload = @enumFromInt(try c.takeInt(u8)),
            .hotcue_color = @enumFromInt(try c.takeInt(u8)),
            .unknown4 = try c.takeInt(u16),
            .needle_lock = @enumFromInt(try c.takeInt(u8)),
            .unknown5 = try c.takeInt(u16),
            .time_mode = @enumFromInt(try c.takeInt(u8)),
            .jog_mode = @enumFromInt(try c.takeInt(u8)),
            .auto_cue = @enumFromInt(try c.takeInt(u8)),
            .master_tempo = @enumFromInt(try c.takeInt(u8)),
            .tempo_range = @enumFromInt(try c.takeInt(u8)),
            .phase_meter = @enumFromInt(try c.takeInt(u8)),
            .unknown6 = try c.takeInt(u16),
        };
    }

    pub fn writeTo(m: *const MySetting, e: *bin.Emitter) bin.WriteError!void {
        try e.putBytes(&m.unknown1);
        try e.putInt(u8, @intFromEnum(m.on_air_display));
        try e.putInt(u8, @intFromEnum(m.lcd_brightness));
        try e.putInt(u8, @intFromEnum(m.quantize));
        try e.putInt(u8, @intFromEnum(m.auto_cue_level));
        try e.putInt(u8, @intFromEnum(m.language));
        try e.putInt(u8, m.unknown2);
        try e.putInt(u8, @intFromEnum(m.jog_ring_brightness));
        try e.putInt(u8, @intFromEnum(m.jog_ring_indicator));
        try e.putInt(u8, @intFromEnum(m.slip_flashing));
        try e.putBytes(&m.unknown3);
        try e.putInt(u8, @intFromEnum(m.disc_slot_illumination));
        try e.putInt(u8, @intFromEnum(m.eject_lock));
        try e.putInt(u8, @intFromEnum(m.sync));
        try e.putInt(u8, @intFromEnum(m.play_mode));
        try e.putInt(u8, @intFromEnum(m.quantize_beat_value));
        try e.putInt(u8, @intFromEnum(m.hotcue_autoload));
        try e.putInt(u8, @intFromEnum(m.hotcue_color));
        try e.putInt(u16, m.unknown4);
        try e.putInt(u8, @intFromEnum(m.needle_lock));
        try e.putInt(u16, m.unknown5);
        try e.putInt(u8, @intFromEnum(m.time_mode));
        try e.putInt(u8, @intFromEnum(m.jog_mode));
        try e.putInt(u8, @intFromEnum(m.auto_cue));
        try e.putInt(u8, @intFromEnum(m.master_tempo));
        try e.putInt(u8, @intFromEnum(m.tempo_range));
        try e.putInt(u8, @intFromEnum(m.phase_meter));
        try e.putInt(u16, m.unknown6);
    }

    /// Default values as found in Rekordbox 6.6.1.
    pub fn default() MySetting {
        return .{
            .unknown1 = .{ 0x78, 0x56, 0x34, 0x12, 0x02, 0x00, 0x00, 0x00 },
            .on_air_display = .on,
            .lcd_brightness = .three,
            .quantize = .on,
            .auto_cue_level = .memory,
            .language = .english,
            .unknown2 = 0x01,
            .jog_ring_brightness = .bright,
            .jog_ring_indicator = .on,
            .slip_flashing = .on,
            .unknown3 = .{ 0x01, 0x01, 0x01 },
            .disc_slot_illumination = .bright,
            .eject_lock = .unlock,
            .sync = .off,
            .play_mode = .single,
            .quantize_beat_value = .full_beat,
            .hotcue_autoload = .on,
            .hotcue_color = .off,
            .unknown4 = 0,
            .needle_lock = .lock,
            .unknown5 = 0,
            .time_mode = .remain,
            .jog_mode = .vinyl,
            .auto_cue = .on,
            .master_tempo = .off,
            .tempo_range = .ten_percent,
            .phase_meter = .type1,
            .unknown6 = 0,
        };
    }
};

/// Payload of a `MYSETTING2.DAT` file.
pub const MySetting2 = struct {
    /// "VINYL SPEED ADJUST" setting.
    vinyl_speed_adjust: VinylSpeedAdjust,
    /// "JOG DISPLAY MODE" setting.
    jog_display_mode: JogDisplayMode,
    /// "PAD/BUTTON BRIGHTNESS" setting.
    pad_button_brightness: PadButtonBrightness,
    /// "JOG LCD BRIGHTNESS" setting.
    jog_lcd_brightness: JogLcdBrightness,
    /// "WAVEFORM DIVISIONS" setting.
    waveform_divisions: WaveformDivisions,
    /// Unknown field (apparently always zero), kept verbatim.
    unknown1: [5]u8,
    /// "WAVEFORM / PHASE METER" setting.
    waveform: Waveform,
    /// Unknown field (apparently always `0x81`), kept verbatim.
    unknown2: u8,
    /// "BEAT JUMP BEAT VALUE" setting.
    beat_jump_beat_value: BeatJumpBeatValue,
    /// Unknown field (apparently always zero), kept verbatim.
    unknown3: [27]u8,

    pub const serialized_len = 40;

    /// The checksum covers just the data section (see `Setting.writeTo`).
    pub const checksum_covers_data_only = true;

    /// Brand string found in `MYSETTING2.DAT` files written by Rekordbox.
    pub const default_brand = "PIONEER";

    /// Version string found in `MYSETTING2.DAT` files written by Rekordbox 6.6.1.
    pub const default_version = "0.001";

    pub fn parse(c: *bin.Cursor) bin.ReadError!MySetting2 {
        return .{
            .vinyl_speed_adjust = @enumFromInt(try c.takeInt(u8)),
            .jog_display_mode = @enumFromInt(try c.takeInt(u8)),
            .pad_button_brightness = @enumFromInt(try c.takeInt(u8)),
            .jog_lcd_brightness = @enumFromInt(try c.takeInt(u8)),
            .waveform_divisions = @enumFromInt(try c.takeInt(u8)),
            .unknown1 = (try c.takeArray(5)).*,
            .waveform = @enumFromInt(try c.takeInt(u8)),
            .unknown2 = try c.takeInt(u8),
            .beat_jump_beat_value = @enumFromInt(try c.takeInt(u8)),
            .unknown3 = (try c.takeArray(27)).*,
        };
    }

    pub fn writeTo(m: *const MySetting2, e: *bin.Emitter) bin.WriteError!void {
        try e.putInt(u8, @intFromEnum(m.vinyl_speed_adjust));
        try e.putInt(u8, @intFromEnum(m.jog_display_mode));
        try e.putInt(u8, @intFromEnum(m.pad_button_brightness));
        try e.putInt(u8, @intFromEnum(m.jog_lcd_brightness));
        try e.putInt(u8, @intFromEnum(m.waveform_divisions));
        try e.putBytes(&m.unknown1);
        try e.putInt(u8, @intFromEnum(m.waveform));
        try e.putInt(u8, m.unknown2);
        try e.putInt(u8, @intFromEnum(m.beat_jump_beat_value));
        try e.putBytes(&m.unknown3);
    }

    /// Default values as found in Rekordbox 6.6.1.
    pub fn default() MySetting2 {
        return .{
            .vinyl_speed_adjust = .touch,
            .jog_display_mode = .auto,
            .pad_button_brightness = .three,
            .jog_lcd_brightness = .three,
            .waveform_divisions = .phrase,
            .unknown1 = @splat(0),
            .waveform = .waveform,
            .unknown2 = 0x81,
            .beat_jump_beat_value = .sixteen_beat,
            .unknown3 = @splat(0),
        };
    }
};

/// Payload of a `DJMMYSETTING.DAT` file. Unlike the other settings files, the
/// checksum covers the whole file, not just the data section.
pub const DJMMySetting = struct {
    /// Unknown field (fixtures carry `78 56 34 12 01 00 00 00 20 00 00 00`),
    /// kept verbatim.
    unknown1: [12]u8,
    /// "CH FADER CURVE" setting.
    channel_fader_curve: ChannelFaderCurve,
    /// "CROSSFADER CURVE" setting.
    crossfader_curve: CrossfaderCurve,
    /// "HEADPHONES PRE EQ" setting.
    headphones_pre_eq: HeadphonesPreEq,
    /// "HEADPHONES MONO SPLIT" setting.
    headphones_mono_split: HeadphonesMonoSplit,
    /// "BEAT FX QUANTIZE" setting.
    beat_fx_quantize: BeatFxQuantize,
    /// "MIC LOW CUT" setting.
    mic_low_cut: MicLowCut,
    /// "TALK OVER MODE" setting.
    talk_over_mode: TalkOverMode,
    /// "TALK OVER LEVEL" setting.
    talk_over_level: TalkOverLevel,
    /// "MIDI CH" setting.
    midi_channel: MidiChannel,
    /// "MIDI BUTTON TYPE" setting.
    midi_button_type: MidiButtonType,
    /// "BRIGHTNESS > DISPLAY" setting.
    display_brightness: MixerDisplayBrightness,
    /// "BRIGHTNESS > INDICATOR" setting.
    indicator_brightness: MixerIndicatorBrightness,
    /// "CH FADER CURVE (LONG FADER)" setting.
    channel_fader_curve_long_fader: ChannelFaderCurveLongFader,
    /// Unknown field (apparently always zero), kept verbatim.
    unknown2: [27]u8,

    pub const serialized_len = 52;

    /// Unlike the other settings files, the checksum covers the whole file
    /// (see `Setting.writeTo`).
    pub const checksum_covers_data_only = false;

    /// Brand string found in `DJMMYSETTING.DAT` files written by Rekordbox.
    pub const default_brand = "PioneerDJ";

    /// Version string found in `DJMMYSETTING.DAT` files written by Rekordbox 6.6.1.
    pub const default_version = "1.000";

    pub fn parse(c: *bin.Cursor) bin.ReadError!DJMMySetting {
        return .{
            .unknown1 = (try c.takeArray(12)).*,
            .channel_fader_curve = @enumFromInt(try c.takeInt(u8)),
            .crossfader_curve = @enumFromInt(try c.takeInt(u8)),
            .headphones_pre_eq = @enumFromInt(try c.takeInt(u8)),
            .headphones_mono_split = @enumFromInt(try c.takeInt(u8)),
            .beat_fx_quantize = @enumFromInt(try c.takeInt(u8)),
            .mic_low_cut = @enumFromInt(try c.takeInt(u8)),
            .talk_over_mode = @enumFromInt(try c.takeInt(u8)),
            .talk_over_level = @enumFromInt(try c.takeInt(u8)),
            .midi_channel = @enumFromInt(try c.takeInt(u8)),
            .midi_button_type = @enumFromInt(try c.takeInt(u8)),
            .display_brightness = @enumFromInt(try c.takeInt(u8)),
            .indicator_brightness = @enumFromInt(try c.takeInt(u8)),
            .channel_fader_curve_long_fader = @enumFromInt(try c.takeInt(u8)),
            .unknown2 = (try c.takeArray(27)).*,
        };
    }

    pub fn writeTo(d: *const DJMMySetting, e: *bin.Emitter) bin.WriteError!void {
        try e.putBytes(&d.unknown1);
        try e.putInt(u8, @intFromEnum(d.channel_fader_curve));
        try e.putInt(u8, @intFromEnum(d.crossfader_curve));
        try e.putInt(u8, @intFromEnum(d.headphones_pre_eq));
        try e.putInt(u8, @intFromEnum(d.headphones_mono_split));
        try e.putInt(u8, @intFromEnum(d.beat_fx_quantize));
        try e.putInt(u8, @intFromEnum(d.mic_low_cut));
        try e.putInt(u8, @intFromEnum(d.talk_over_mode));
        try e.putInt(u8, @intFromEnum(d.talk_over_level));
        try e.putInt(u8, @intFromEnum(d.midi_channel));
        try e.putInt(u8, @intFromEnum(d.midi_button_type));
        try e.putInt(u8, @intFromEnum(d.display_brightness));
        try e.putInt(u8, @intFromEnum(d.indicator_brightness));
        try e.putInt(u8, @intFromEnum(d.channel_fader_curve_long_fader));
        try e.putBytes(&d.unknown2);
    }

    /// Default values as found in Rekordbox 6.6.1.
    pub fn default() DJMMySetting {
        return .{
            .unknown1 = .{ 0x78, 0x56, 0x34, 0x12, 0x01, 0x00, 0x00, 0x00, 0x20, 0x00, 0x00, 0x00 },
            .channel_fader_curve = .linear,
            .crossfader_curve = .fast_cut,
            .headphones_pre_eq = .post_eq,
            .headphones_mono_split = .stereo,
            .beat_fx_quantize = .on,
            .mic_low_cut = .on,
            .talk_over_mode = .advanced,
            .talk_over_level = .minus_18_db,
            .midi_channel = .one,
            .midi_button_type = .toggle,
            .display_brightness = .five,
            .indicator_brightness = .three,
            .channel_fader_curve_long_fader = .exponential,
            .unknown2 = @splat(0),
        };
    }
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

/// CRC-16/XMODEM (poly 0x1021, init 0x0000, no reflection, no final xor).
/// <https://reveng.sourceforge.io/crc-catalogue/all.htm#crc.cat.crc-16-xmodem>
fn crc16Xmodem(data: []const u8) u16 {
    var crc: u16 = 0;
    for (data) |byte| {
        crc ^= @as(u16, byte) << 8;
        for (0..8) |_| {
            crc = if (crc & 0x8000 != 0) (crc << 1) ^ 0x1021 else crc << 1;
        }
    }
    return crc;
}

const testing = std.testing;

test "crc16-xmodem known answer" {
    try testing.expectEqual(@as(u16, 0x31C3), crc16Xmodem("123456789"));
}

test "devsetting default roundtrip" {
    const s = Setting(DevSetting).default();
    const out = try s.serialize(testing.allocator);
    defer testing.allocator.free(out);
    try testing.expectEqual(@as(usize, 140), out.len);

    const parsed = try Setting(DevSetting).parse(out);
    try testing.expectEqual(s, parsed);
    try testing.expectEqualStrings("PIONEER DJ", parsed.brandString());
    try testing.expectEqualStrings("rekordbox", parsed.softwareString());
    try testing.expectEqualStrings("6.6.1", parsed.versionString());
}

test "mysetting default roundtrip" {
    const s = Setting(MySetting).default();
    const out = try s.serialize(testing.allocator);
    defer testing.allocator.free(out);
    try testing.expectEqual(@as(usize, 148), out.len);

    const parsed = try Setting(MySetting).parse(out);
    try testing.expectEqual(s, parsed);
    try testing.expectEqualStrings("PIONEER", parsed.brandString());
    try testing.expectEqualStrings("rekordbox", parsed.softwareString());
    try testing.expectEqualStrings("0.001", parsed.versionString());
}

test "devsetting unknown fields and enum values roundtrip verbatim" {
    var s = Setting(DevSetting).default();
    s.data.unknown1 = .{ 1, 2, 3, 4, 5, 6, 7, 8, 9 };
    s.data.unknown2 = 0xAA;
    s.data.unknown3 = [_]u8{0x5A} ** 18;
    s.data.key_display_format = @enumFromInt(0x7F);
    s.unknown = 0xBEEF;

    const out = try s.serialize(testing.allocator);
    defer testing.allocator.free(out);
    const parsed = try Setting(DevSetting).parse(out);
    try testing.expectEqual(s, parsed);

    const out2 = try parsed.serialize(testing.allocator);
    defer testing.allocator.free(out2);
    try testing.expectEqualSlices(u8, out, out2);
}

test "mysetting unknown fields and enum values roundtrip verbatim" {
    var s = Setting(MySetting).default();
    s.data.unknown1 = .{ 1, 2, 3, 4, 5, 6, 7, 8 };
    s.data.unknown2 = 0xAA;
    s.data.unknown3 = .{ 0x5A, 0xA5, 0x5A };
    s.data.unknown4 = 0xDEAD;
    s.data.unknown5 = 0xBEEF;
    s.data.unknown6 = 0xCAFE;
    s.data.language = @enumFromInt(0x7F);
    s.data.tempo_range = @enumFromInt(0x00);
    s.unknown = 0xBEEF;

    const out = try s.serialize(testing.allocator);
    defer testing.allocator.free(out);
    const parsed = try Setting(MySetting).parse(out);
    try testing.expectEqual(s, parsed);

    const out2 = try parsed.serialize(testing.allocator);
    defer testing.allocator.free(out2);
    try testing.expectEqualSlices(u8, out, out2);
}

test "mysetting2 default roundtrip" {
    const s = Setting(MySetting2).default();
    const out = try s.serialize(testing.allocator);
    defer testing.allocator.free(out);
    try testing.expectEqual(@as(usize, 148), out.len);

    const parsed = try Setting(MySetting2).parse(out);
    try testing.expectEqual(s, parsed);
    try testing.expectEqualStrings("PIONEER", parsed.brandString());
    try testing.expectEqualStrings("rekordbox", parsed.softwareString());
    try testing.expectEqualStrings("0.001", parsed.versionString());
}

test "djmmysetting default roundtrip" {
    const s = Setting(DJMMySetting).default();
    const out = try s.serialize(testing.allocator);
    defer testing.allocator.free(out);
    try testing.expectEqual(@as(usize, 160), out.len);

    const parsed = try Setting(DJMMySetting).parse(out);
    try testing.expectEqual(s, parsed);
    try testing.expectEqualStrings("PioneerDJ", parsed.brandString());
    try testing.expectEqualStrings("rekordbox", parsed.softwareString());
    try testing.expectEqualStrings("1.000", parsed.versionString());
}

test "mysetting2 unknown fields and enum values roundtrip verbatim" {
    var s = Setting(MySetting2).default();
    s.data.unknown1 = .{ 1, 2, 3, 4, 5 };
    s.data.unknown2 = 0xAA;
    s.data.unknown3 = [_]u8{0x5A} ** 27;
    s.data.waveform = @enumFromInt(0x7F);
    s.unknown = 0xBEEF;

    const out = try s.serialize(testing.allocator);
    defer testing.allocator.free(out);
    const parsed = try Setting(MySetting2).parse(out);
    try testing.expectEqual(s, parsed);

    const out2 = try parsed.serialize(testing.allocator);
    defer testing.allocator.free(out2);
    try testing.expectEqualSlices(u8, out, out2);
}

test "djmmysetting unknown fields and enum values roundtrip verbatim" {
    var s = Setting(DJMMySetting).default();
    s.data.unknown1 = .{ 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12 };
    s.data.unknown2 = [_]u8{0x5A} ** 27;
    s.data.midi_channel = @enumFromInt(0x7F);
    s.unknown = 0xBEEF;

    const out = try s.serialize(testing.allocator);
    defer testing.allocator.free(out);
    const parsed = try Setting(DJMMySetting).parse(out);
    try testing.expectEqual(s, parsed);

    const out2 = try parsed.serialize(testing.allocator);
    defer testing.allocator.free(out2);
    try testing.expectEqualSlices(u8, out, out2);
}

test "parse rejects invalid structure" {
    var e = bin.Emitter.init(testing.allocator);
    defer e.deinit();
    try Setting(DevSetting).default().writeTo(&e);
    try testing.expectEqual(@as(usize, 140), e.written().len);

    var bad = try testing.allocator.dupe(u8, e.written());
    defer testing.allocator.free(bad);
    std.mem.writeInt(u32, bad[0..4], 0x20, .little);
    try testing.expectError(error.InvalidFormat, Setting(DevSetting).parse(bad));

    std.mem.writeInt(u32, bad[0..4], 0x60, .little);
    std.mem.writeInt(u32, bad[100..104], 40, .little);
    try testing.expectError(error.InvalidFormat, Setting(DevSetting).parse(bad));

    const long = try testing.allocator.alloc(u8, 141);
    defer testing.allocator.free(long);
    @memcpy(long[0..140], e.written());
    long[140] = 0;
    try testing.expectError(error.InvalidFormat, Setting(DevSetting).parse(long));

    try testing.expectError(error.UnexpectedEof, Setting(DevSetting).parse(e.written()[0..139]));
}

test "setting type mismatch is rejected" {
    const out = try Setting(MySetting).default().serialize(testing.allocator);
    defer testing.allocator.free(out);
    try testing.expectError(error.InvalidFormat, Setting(DevSetting).parse(out));
}

test "DEVSETTING.DAT fixtures roundtrip byte-identical" {
    const alloc = testing.allocator;
    const io = testing.io;
    var dir = try std.Io.Dir.cwd().openDir(io, "testdata", .{ .iterate = true });
    defer dir.close(io);
    var walker = try dir.walk(alloc);
    defer walker.deinit();

    var count: usize = 0;
    while (try walker.next(io)) |entry| {
        if (entry.kind != .file) continue;
        if (!std.mem.eql(u8, entry.basename, "DEVSETTING.DAT")) continue;

        const input = try dir.readFileAlloc(io, entry.path, alloc, std.Io.Limit.limited(1 << 20));
        defer alloc.free(input);
        const parsed = try Setting(DevSetting).parse(input);
        const output = try parsed.serialize(alloc);
        defer alloc.free(output);
        try testing.expectEqualSlices(u8, input, output);
        count += 1;
    }

    // Five devsetting fixtures plus two complete device exports.
    try testing.expect(count >= 7);
}

test "MYSETTING.DAT fixtures roundtrip byte-identical" {
    const alloc = testing.allocator;
    const io = testing.io;
    var dir = try std.Io.Dir.cwd().openDir(io, "testdata", .{ .iterate = true });
    defer dir.close(io);
    var walker = try dir.walk(alloc);
    defer walker.deinit();

    var count: usize = 0;
    while (try walker.next(io)) |entry| {
        if (entry.kind != .file) continue;
        if (!std.mem.eql(u8, entry.basename, "MYSETTING.DAT")) continue;

        const input = try dir.readFileAlloc(io, entry.path, alloc, std.Io.Limit.limited(1 << 20));
        defer alloc.free(input);
        const parsed = try Setting(MySetting).parse(input);
        const output = try parsed.serialize(alloc);
        defer alloc.free(output);
        try testing.expectEqualSlices(u8, input, output);
        count += 1;
    }

    // Thirty-two mysetting fixtures plus two complete device exports.
    try testing.expect(count >= 34);
}

test "MYSETTING2.DAT fixtures roundtrip byte-identical" {
    const alloc = testing.allocator;
    const io = testing.io;
    var dir = try std.Io.Dir.cwd().openDir(io, "testdata", .{ .iterate = true });
    defer dir.close(io);
    var walker = try dir.walk(alloc);
    defer walker.deinit();

    var count: usize = 0;
    while (try walker.next(io)) |entry| {
        if (entry.kind != .file) continue;
        if (!std.mem.eql(u8, entry.basename, "MYSETTING2.DAT")) continue;

        const input = try dir.readFileAlloc(io, entry.path, alloc, std.Io.Limit.limited(1 << 20));
        defer alloc.free(input);
        const parsed = try Setting(MySetting2).parse(input);
        const output = try parsed.serialize(alloc);
        defer alloc.free(output);
        try testing.expectEqualSlices(u8, input, output);
        count += 1;
    }

    // Fourteen mysetting2 fixtures plus two complete device exports.
    try testing.expect(count >= 16);
}

test "DJMMYSETTING.DAT fixtures roundtrip byte-identical" {
    const alloc = testing.allocator;
    const io = testing.io;
    var dir = try std.Io.Dir.cwd().openDir(io, "testdata", .{ .iterate = true });
    defer dir.close(io);
    var walker = try dir.walk(alloc);
    defer walker.deinit();

    var count: usize = 0;
    while (try walker.next(io)) |entry| {
        if (entry.kind != .file) continue;
        if (!std.mem.eql(u8, entry.basename, "DJMMYSETTING.DAT")) continue;

        const input = try dir.readFileAlloc(io, entry.path, alloc, std.Io.Limit.limited(1 << 20));
        defer alloc.free(input);
        const parsed = try Setting(DJMMySetting).parse(input);
        const output = try parsed.serialize(alloc);
        defer alloc.free(output);
        try testing.expectEqualSlices(u8, input, output);
        count += 1;
    }

    // Twenty-three djmmysetting fixtures plus two complete device exports.
    try testing.expect(count >= 25);
}

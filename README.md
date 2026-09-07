# Rekordlib

This library provides tools to read, write, and create the Rekordbox export files:
  - export.pdb/exportExt.pdb
  - OneLibrary (exportLibrary.db)
  - ANLZ (.DAT, .EXT, .2EX)
  - Setting files (DEVSETTING.DAT, DJMMYSETTING.DAT, MYSETTING.DAT, MYSETTING2.DAT)

It intends to not be very opinionated despite providing helpers to easily build a Rekordbox library manager app. See [USAGE.md](docs/USAGE.md).

The code for pdb, ANLZ and setting files was initially a port from [rekordcrate](https://github.com/Holzhaus/rekordcrate). This library is written in Zig, and its purpose has been to be a way for me to get more into the language and to try different ideas for my Rekordbox RE adventure. I intend to bring some (hopefully, the best) of those ideas back to rekordcrate. In the meantime, feel free to use this library as you please and get yourself into the world of Rekordbox reverse engineering.

## Build

Requires Zig 0.16.0 or newer.

```bash
zig build
```

## Dependencies

The OneLibrary store needs SQLCipher, picked by the `-Donelibrary` build option:
  - `system-sqlcipher` (default): links the system `libsqlcipher`;
  - `vendored-sqlcipher`: compiles a bundled, `rl_`-prefixed SQLCipher amalgamation (SQLite included) via zig cc — no system library needed, and no symbol collision with a consumer's own SQLCipher;
  - `off`: no OneLibrary support, no SQLCipher.

```bash
zig build -Donelibrary=vendored-sqlcipher
```

## Build API docs

```bash
zig build docs  # output in zig-out/docs
```

## Use as a dependency

```bash
zig fetch --save=rekordlib <url-or-path-to-this-repo>
```

```zig
const rekordlib = b.dependency("rekordlib", .{});
exe.linkLibrary(rekordlib.artifact("rekordlib"));
```

The `-Donelibrary` values pass through as dependency options, e.g. `b.dependency("rekordlib", .{ .onelibrary = "vendored-sqlcipher" })`.

## License

MPL-2.0 License. See [LICENSE](LICENSE) for more information.

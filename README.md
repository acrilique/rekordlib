# Rekordlib

This library tries to provide tools to deal with the Rekordbox export files:
  - export.pdb/exportExt.pdb
  - OneLibrary (exportLibrary.db)
  - ANLZ (.DAT, .EXT, .2EX)
  - Setting files (DEVSETTING.DAT, DJMMYSETTING.DAT, MYSETTING.DAT, MYSETTING2.DAT)

It indends to not be very opinionated despite providing helpers to easily build a Rekordbox library manager app. See [USAGE.md](docs/USAGE.md).

The code for pdb, ANLZ and setting files was initially a port from [rekordcrate](https://github.com/Holzhaus/rekordcrate).

## Dependencies

libsqlcipher is required, although a vendored version is provided with the `-Donelibrary=vendored-sqlcipher` build option in case the system cannot provide it. The vendored version will inevitebly run slower.

## Build

```bash
zig build -Donelibrary=vendored-sqlcipher
```

## Build API docs

```bash
zig build docs -Donelibrary=vendored-sqlcipher
```

## License

MPL-2.0 License. See [LICENSE](LICENSE) for more information.
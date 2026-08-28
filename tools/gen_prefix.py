#!/usr/bin/env python3
"""Generate symbol-renaming artifacts for the vendored SQLCipher amalgamation.

Reads the upstream sqlite3.h plus a hand-listed sqlcipher_* surface and emits:
  - rl_rename.h    : `#define <sym> rl_<sym>` lines, force-included when
                     compiling the amalgamation (single TU -> every internal
                     reference renames consistently).
  - rl_sqlite3.h   : consumer copy of sqlite3.h with the same symbols
                     textually renamed (no macro pollution for consumers).
  - rl_symbols.txt : the exact symbol list (for the nm verification).

Usage: gen_prefix.py <sqlite3.h> <sqlcipher_syms> <outdir>
       gen_prefix.py --verify <object>   (ELF/COFF via nm, Mach-O via nlist)
"""

from __future__ import annotations

import re
import struct
import subprocess
import sys
from pathlib import Path

# sqlcipher.h public surface that must also be prefixed (collides with a
# consumer-embedded SQLCipher just like sqlite3_* does).
SQLCIPHER_SYMS = [
    "sqlcipher_codec_pragma",
    "sqlcipherCodecAttach",
    "sqlcipherCodecGetKey",
    "sqlcipher_find_db_index",
    "sqlcipher_free",
    "sqlcipher_get_provider",
    "sqlcipher_init_memmethods",
    "sqlcipher_ismemset",
    "sqlcipher_log",
    "sqlcipher_malloc",
    "sqlcipher_memcmp",
    "sqlcipher_memset",
    "sqlcipher_mutex",
    "sqlcipher_register_provider",
    "sqlcipher_version",
    # wired via -D on the command line; renaming keeps the amalgamation
    # self-consistent (the macro expands at the call sites inside sqlite3.c).
    "sqlcipher_extra_init",
    "sqlcipher_extra_shutdown",
    # globals the amalgamation defines outside SQLITE_API surfaces
    # (pager.c extensions and codec helpers - found by nm, kept verifiable):
    "sqlcipher_log_write",
    "sqlcipherPagerCodec",
    "sqlcipherPagerGetCodec",
    "sqlcipherPagerSetCodec",
    "sqlite3pager_error",
    "sqlite3pager_is_sj_pgno",
    "sqlite3pager_reset",
    "xoshiro_next",
    # windows-only helpers defined in os_win.c (not in sqlite3.h)
    "sqlite3_win32_is_nt",
    "sqlite3_win32_mbcs_to_utf8",
    "sqlite3_win32_mbcs_to_utf8_v2",
    "sqlite3_win32_sleep",
    "sqlite3_win32_unicode_to_utf8",
    "sqlite3_win32_utf8_to_mbcs",
    "sqlite3_win32_utf8_to_mbcs_v2",
    "sqlite3_win32_utf8_to_unicode",
    "sqlite3_win32_write_debug",
]


def extract_api_symbols(sqlite3_h: str) -> list[str]:
    """Return every sqlite3_* identifier declared with SQLITE_API."""
    syms: set[str] = set()
    # Functions: SQLITE_API ... sqlite3_foo(
    for m in re.finditer(r"\bsqlite3_[A-Za-z0-9_]+\s*\(", sqlite3_h):
        syms.add(m.group(0)[: m.end() - m.start() - 1].rstrip())
    # Data (arrays / extern objects): SQLITE_API extern ... sqlite3_foo[
    for m in re.finditer(r"\bsqlite3_[A-Za-z0-9_]+\s*\[", sqlite3_h):
        syms.add(m.group(0)[: m.end() - m.start() - 1].rstrip())
    # Data (scalar objects): SQLITE_API extern <type> sqlite3_foo;
    for m in re.finditer(r"\bsqlite3_[A-Za-z0-9_]+\s*;", sqlite3_h):
        syms.add(m.group(0)[: m.end() - m.start() - 1].rstrip())
    # Only SQLITE_API-declared names are the exported surface; declarations
    # without it (e.g. inside commented examples) must not leak in.
    api_syms: set[str] = set()
    pos = 0
    while True:
        i = sqlite3_h.find("SQLITE_API", pos)
        if i < 0:
            break
        # take the declaration up to the terminating ; (functions may span
        # several lines and contain parentheses in params)
        j = sqlite3_h.find(";", i)
        if j < 0:
            break
        decl = sqlite3_h[i:j]
        for s in syms:
            if re.search(rf"\b{re.escape(s)}\b", decl):
                api_syms.add(s)
        pos = i + 1
    return sorted(api_syms)


def defined_globals(path: Path) -> list[str]:
    """Defined external symbols of an object file, prefix-agnostic."""
    data = path.read_bytes()
    if data[:4] == b"\xcf\xfa\xed\xfe":  # Mach-O 64 LE: no binutils nm
        return macho_defined_globals(data)
    if data[:4] not in (b"\x7fELF", b"\x00\x00\x00\x01\x00\x00\x00") and not (
        data[:2] in (b"MZ",) or data[:4] == b"\x00\x00\xff\xff"
    ):
        pass  # fall through to nm; it knows ELF/COFF/Mach-O when llvm-built
    out = subprocess.run(
        ["nm", "--defined-only", str(path)],
        capture_output=True,
        text=True,
        check=True,
    ).stdout
    names = []
    for line in out.splitlines():
        parts = line.split()
        if len(parts) >= 3 and parts[1].isupper():
            names.append(parts[2])
    return names


def macho_defined_globals(data: bytes) -> list[str]:
    """nlist_64 walk (binutils nm cannot read Mach-O)."""
    MH_OBJECT = 0x1
    LC_SYMTAB = 0x2
    N_EXT = 0x01
    _magic, _cpu, _sub, filetype, ncmds, _szcmds, _flags = struct.unpack_from(
        "<IiiIIII", data, 0
    )
    assert filetype == MH_OBJECT
    off = 32
    names: list[str] = []
    for _ in range(ncmds):
        cmd, cmdsize = struct.unpack_from("<II", data, off)
        if cmd == LC_SYMTAB:
            symoff, nsyms, stroff, strsize = struct.unpack_from("<IIII", data, off + 8)
            strtab = data[stroff : stroff + strsize]
            for i in range(nsyms):
                n_strx, n_type, _n_sect, _n_desc, _val = struct.unpack_from(
                    "<IBBHQ", data, symoff + 16 * i
                )
                if (n_type & N_EXT) and (n_type & 0x0E) == 0x0E:  # N_SECT
                    end = strtab.index(b"\0", n_strx)
                    names.append(strtab[n_strx:end].decode().lstrip("_"))
            break
        off += cmdsize
    return names


def verify_object(path: Path) -> int:
    names = defined_globals(path)
    bad = [n for n in names if not n.startswith("rl_")]
    # COFF debug-section pseudo-symbols are not code symbols
    bad = [n for n in bad if not n.startswith((".debug", "$"))]
    print(f"{path}: {len(names)} defined globals, non-rl: {bad}")
    return 1 if bad else 0


def main() -> None:
    if len(sys.argv) == 3 and sys.argv[1] == "--verify":
        sys.exit(verify_object(Path(sys.argv[2])))
    sqlite3_h_path = Path(sys.argv[1])
    sqlcipher_syms_path = Path(sys.argv[2])
    outdir = Path(sys.argv[3])
    header = sqlite3_h_path.read_text()
    syms = extract_api_symbols(header)
    syms += [s for s in SQLCIPHER_SYMS if s not in syms]
    # The extension entry points are declared via SQLITE_API only when their
    # feature is enabled; add the ones the amalgamation can export.
    for ext in ("fts3", "fts5", "rtree", "rbu", "session"):
        pass  # features are compiled out in our minimal flag set

    rename_lines = [f"#define {s} rl_{s}" for s in syms]
    (outdir / "rl_rename.h").write_text(
        "\n".join(
            [
                "/* Generated by tools/gen_prefix.py - do not edit.",
                 " * Renames every exported sqlite3_/sqlcipher_ symbol to its",
                 " * rl_-prefixed form so a vendored build cannot collide with",
                 " * a consumer-embedded SQLCipher.",
                 " */",
                *rename_lines,
                "",
            ]
        )
    )

    def rename_in_text(text: str) -> str:
        for s in syms:
            text = re.sub(rf"\b{re.escape(s)}\b", f"rl_{s}", text)
        return text

    renamed_header = rename_in_text(header)
    # The consumer header keeps its include guard etc.; only symbols changed.
    (outdir / "rl_sqlite3.h").write_text(renamed_header)

    (outdir / "rl_symbols.txt").write_text("\n".join(syms) + "\n")

    print(f"{len(syms)} symbols: {syms[:5]} ... {syms[-5:]}")


if __name__ == "__main__":
    main()

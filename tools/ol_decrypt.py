#!/usr/bin/env python3
"""Decrypt / re-encrypt a Pioneer OneLibrary `exportLibrary.db`.

The db is SQLCipher v4 with default parameters in passphrase mode:

* passphrase: rbox 0.1.5 `conn.rs` MAGIC with each byte decremented
  (`s9heeos...` -> `r8gddnr...`; not hex, so raw-key mode is impossible)
* key = PBKDF2-HMAC-SHA512(passphrase, salt = file bytes 0..16,
  256000 iterations, 32 bytes)
* hmac_key = PBKDF2-HMAC-SHA512(key, salt XOR 0x3a per byte, 2 iterations,
  32 bytes)  [verified against sqlcipher src/sqlcipher.c, 2026-08-23]
* per 4096-byte page: [ciphertext 4016][IV 16][HMAC-SHA512 64]
  (80 reserved bytes). Page 1's first 16 plaintext bytes - the
  "SQLite format 3\\0" magic - are replaced by the salt, so its ciphertext
  slot is 16 bytes shorter and shifted down by 16.
* page HMAC = HMAC-SHA512(hmac_key, ciphertext+IV || little-endian page
  number (1-based))

The decrypted output is a plain SQLite image: 4096-byte pages with the
80-byte reserve zero-filled (usable bytes 4016 per page, 4000 on page 1
after its 16-byte magic). Re-encryption inverts that; page IVs are fresh
random (SQLCipher never reuses stored IVs on write; readers take the IV
from the page itself).

Usage:
  ol_decrypt.py decrypt <in.db> <out.db> [--check]   --check verifies page HMACs
  ol_decrypt.py encrypt <in.db> <out.db>             salt = page-1 magic slot
  ol_decrypt.py info <in.db>                         crypto facts + HMAC audit

Mutating fixtures: edit a decrypted copy with the sqlite3 CLI, then
`encrypt` it back - no external tool needed.
"""

from __future__ import annotations

import argparse
import hashlib
import hmac as hmac_mod
import os
import sys
from pathlib import Path

from Cryptodome.Cipher import AES

PAGE_SIZE = 4096
USABLE = PAGE_SIZE - 80  # 4016 ciphertext bytes per page
KDF_ITER = 256_000
FAST_KDF_ITER = 2
HMAC_SALT_MASK = 0x3A

MAGIC = "s9heeos5l958941bs7dr{cll1fm7rzunc4usccy916kn85wf{75j6p9gosrszrmt"
PASSPHRASE = bytes(b - 1 for b in MAGIC.encode())


def derive_keys(salt: bytes) -> tuple[bytes, bytes]:
    key = hashlib.pbkdf2_hmac("sha512", PASSPHRASE, salt, KDF_ITER, dklen=32)
    hmac_salt = bytes(b ^ HMAC_SALT_MASK for b in salt)
    hmac_key = hashlib.pbkdf2_hmac("sha512", key, hmac_salt, FAST_KDF_ITER, dklen=32)
    return key, hmac_key


def page_hmac(hmac_key: bytes, data: bytes, iv: bytes, pgno: int) -> bytes:
    h = hmac_mod.new(hmac_key, digestmod=hashlib.sha512)
    h.update(data)
    h.update(iv)
    h.update(pgno.to_bytes(4, "little"))
    return h.digest()




def decrypt_file(src: bytes, check: bool) -> tuple[bytes, int, int]:
    salt = src[:16]
    key, hmac_key = derive_keys(salt)
    out = bytearray()
    n_pages = len(src) // PAGE_SIZE
    n_bad = 0
    for i in range(n_pages):
        pgno = i + 1
        page = src[i * PAGE_SIZE : (i + 1) * PAGE_SIZE]
        if pgno == 1:
            # the salt replaces the plaintext magic; ciphertext slot is 16 short
            ct = page[16:USABLE]
        else:
            ct = page[:USABLE]
        iv = page[USABLE : USABLE + 16]
        mac = page[USABLE + 16 :]
        if check and not hmac_mod.compare_digest(mac, page_hmac(hmac_key, ct, iv, pgno)):
            n_bad += 1
        plain = AES.new(key, AES.MODE_CBC, iv).decrypt(ct)
        if pgno == 1:
            out += b"SQLite format 3\x00" + plain + b"\x00" * 80
        else:
            out += plain + b"\x00" * 80
    return bytes(out), n_pages, n_bad


def encrypt_file(src: bytes) -> tuple[bytes, int]:
    if len(src) % PAGE_SIZE != 0:
        raise SystemExit(f"plaintext must be {PAGE_SIZE}-byte pages, got {len(src)}")
    salt = os.urandom(16)
    key, hmac_key = derive_keys(salt)
    out = bytearray()
    n_pages = len(src) // PAGE_SIZE
    for i in range(n_pages):
        pgno = i + 1
        page = src[i * PAGE_SIZE : (i + 1) * PAGE_SIZE]
        iv = os.urandom(16)
        if pgno == 1:
            if page[:16] != b"SQLite format 3\x00":
                raise SystemExit("plaintext page 1 does not carry the sqlite magic")
            ct = AES.new(key, AES.MODE_CBC, iv).encrypt(page[16:USABLE])
            out += salt + ct + iv + page_hmac(hmac_key, ct, iv, pgno)
        else:
            ct = AES.new(key, AES.MODE_CBC, iv).encrypt(page[:USABLE])
            out += ct + iv + page_hmac(hmac_key, ct, iv, pgno)
    return bytes(out), n_pages


def cmd_info(args: argparse.Namespace) -> None:
    src = Path(args.infile).read_bytes()
    salt = src[:16]
    key, hmac_key = derive_keys(salt)
    _, n_pages, n_bad = decrypt_file(src, check=True)
    print(f"file: {args.infile}")
    print(f"size: {len(src)} ({n_pages} pages of {PAGE_SIZE})")
    print(f"salt: {salt.hex()}")
    print(f"key: {key.hex()}")
    print(f"hmac key: {hmac_key.hex()}")
    print(f"hmac audit: {n_pages - n_bad}/{n_pages} pages ok")


def cmd_decrypt(args: argparse.Namespace) -> None:
    src = Path(args.infile).read_bytes()
    out, n_pages, n_bad = decrypt_file(src, check=args.check)
    if n_bad:
        print(f"WARNING: {n_bad}/{n_pages} page HMAC mismatches", file=sys.stderr)
        if args.check:
            sys.exit(1)
    Path(args.outfile).write_bytes(out)
    print(f"decrypted {n_pages} pages -> {args.outfile}")


def cmd_encrypt(args: argparse.Namespace) -> None:
    src = Path(args.infile).read_bytes()
    out, n_pages = encrypt_file(src)
    Path(args.outfile).write_bytes(out)
    print(f"encrypted {n_pages} pages -> {args.outfile}")


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    sub = parser.add_subparsers(dest="cmd", required=True)
    p = sub.add_parser("info", help="show crypto facts of an encrypted db")
    p.add_argument("infile")
    p.set_defaults(func=cmd_info)
    p = sub.add_parser("decrypt", help="encrypted -> plaintext SQLite db")
    p.add_argument("infile")
    p.add_argument("outfile")
    p.add_argument("--check", action="store_true", help="fail on HMAC mismatch")
    p.set_defaults(func=cmd_decrypt)
    p = sub.add_parser("encrypt", help="plaintext SQLite db -> encrypted")
    p.add_argument("infile")
    p.add_argument("outfile")
    p.set_defaults(func=cmd_encrypt)
    args = parser.parse_args()
    args.func(args)


if __name__ == "__main__":
    main()

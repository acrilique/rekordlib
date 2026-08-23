/* Compile this shim, never sqlite3.c directly: force-including the rename
 * header before the amalgamation renames every exported sqlite3_/
 * sqlcipher_ symbol to its rl_ form (see README.md in this directory).
 * The relative includes resolve next to this file. */
#include "rl_rename.h"
#include "sqlite3.c"

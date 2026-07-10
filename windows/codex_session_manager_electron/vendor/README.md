# Bundled SQLite CLI

`npm run package:win` runs `scripts/prepare_windows_sqlite.sh`, which downloads and verifies the official Windows x64 SQLite command-line tools and extracts only `sqlite3.exe` into this directory.

- SQLite: 3.53.3 (`3530300`)
- Source: `https://www.sqlite.org/2026/sqlite-tools-win-x64-3530300.zip`
- Archive SHA3-256: `b943f8ec7ab77433df44520a27ea65744a792e68a25c05b48823168496b3ccdb`

The generated `sqlite3.exe` is ignored by git and is included in the packaged portable application.

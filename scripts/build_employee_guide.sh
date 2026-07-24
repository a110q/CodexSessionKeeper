#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PDF="$ROOT_DIR/dist/Codex会话管理-安装与使用说明.pdf"
command -v pdfinfo >/dev/null || { echo "pdfinfo is required" >&2; exit 1; }
npm --prefix "$ROOT_DIR/windows/codex_session_manager_electron" run guide:pdf
PAGES="$(pdfinfo "$PDF" | awk '/^Pages:/ { print $2 }')"
if [[ ! "$PAGES" =~ ^[1-5]$ ]]; then
  echo "Employee guide must contain 1-5 pages; got: ${PAGES:-unknown}" >&2
  exit 1
fi
echo "$PDF"

#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT_DIR"

export CODEX_RUN_MEMORY_REGRESSION=1

swift test --filter BackupVerificationTests.memoryRegressionFullVerificationReleasesJSONObjectsPerLine
swift test --filter BackupVerificationTests.memoryRegressionChangedChunkVerificationReleasesBuffersPerChunk
swift test --filter BackupAgentTests.memoryRegressionInitialScanStaysBoundedAcrossManySessions
swift test --filter BackupIntegrityAuditorTests.memoryRegressionRepairReleasesJSONObjectsPerLine

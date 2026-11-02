#!/usr/bin/env bash
set -uo pipefail

MODE="${1:?usage: run-probe.sh linux|macos}"
if [[ "$MODE" != "linux" && "$MODE" != "macos" ]]; then
  echo "Unsupported mode: $MODE" >&2
  exit 64
fi

RESULTS_DIR="${PROBE_RESULTS_DIR:-/artifacts}"
mkdir -p "$RESULTS_DIR"
RESULTS_DIR="$(cd "$RESULTS_DIR" && pwd)"
SUMMARY="$RESULTS_DIR/summary.json"

{
  echo "mode=$MODE"
  echo "kernel=$(uname -srm)"
  echo "java_home=${JAVA_HOME:-}"
  java -version 2>&1
  gradle --version
  if [[ "$MODE" == "macos" ]]; then
    xcode-select -p
    xcodebuild -version
    xcrun --sdk iphoneos --show-sdk-version
  fi
} >"$RESULTS_DIR/environment.log" 2>&1

set +e
gradle --no-daemon --console=plain --stacktrace clean compileKotlinIosArm64 \
  >"$RESULTS_DIR/compile-klib.log" 2>&1
COMPILE_STATUS=$?
set -e

python3 - "$RESULTS_DIR" "$COMPILE_STATUS" <<'PY'
import json, pathlib, sys, zipfile
out = pathlib.Path(sys.argv[1])
status = int(sys.argv[2])
project = pathlib.Path.cwd()
klibs = sorted(project.glob("build/**/*.klib"))
entries = []
for path in klibs:
    names = []
    try:
        with zipfile.ZipFile(path) as archive:
            names = archive.namelist()
    except Exception as exc:
        names = [f"INSPECTION_ERROR: {exc}"]
    bitcode = [name for name in names if name.lower().endswith((".bc", ".ll"))]
    entries.append({
        "path": str(path.relative_to(project)),
        "bytes": path.stat().st_size,
        "bitcode_or_llvm_ir_entries": bitcode[:100],
        "bitcode_or_llvm_ir_entry_count": len(bitcode),
    })
(out / "klib-inventory.json").write_text(json.dumps({
    "compile_exit": status,
    "klib_count": len(klibs),
    "klibs": entries,
}, indent=2))
PY

if [[ "$COMPILE_STATUS" -ne 0 ]]; then
  cat >"$SUMMARY" <<EOF
{
  "mode": "$MODE",
  "compile_klib_exit": $COMPILE_STATUS,
  "framework_link_attempted": false,
  "classification": "KLIB compilation failed; inspect compile-klib.log"
}
EOF
  echo "KLIB compilation failed with exit code $COMPILE_STATUS"
  exit "$COMPILE_STATUS"
fi

set +e
gradle --no-daemon --console=plain --stacktrace linkDebugFrameworkIosArm64 \
  >"$RESULTS_DIR/link-framework.log" 2>&1
LINK_STATUS=$?
set -e

python3 - "$MODE" "$COMPILE_STATUS" "$LINK_STATUS" "$RESULTS_DIR" <<'PY'
import json, pathlib, re, sys
mode, compile_status, link_status = sys.argv[1], int(sys.argv[2]), int(sys.argv[3])
out = pathlib.Path(sys.argv[4])
log = (out / "link-framework.log").read_text(errors="replace")
host_block = bool(re.search(
    r"Target .*iosArm64.*not available for output kind.*(linux_x64|linux)",
    log, re.IGNORECASE | re.DOTALL
))
if mode == "linux":
    classification = (
        "stock_host_gate_reproduced" if host_block else
        "framework_link_unexpectedly_succeeded" if link_status == 0 else
        "framework_link_failed_for_another_reason"
    )
else:
    classification = (
        "macos_reference_framework_succeeded" if link_status == 0 else
        "macos_reference_framework_failed"
    )
summary = {
    "mode": mode,
    "compile_klib_exit": compile_status,
    "framework_link_exit": link_status,
    "explicit_linux_host_gate_detected": host_block,
    "classification": classification,
    "framework_artifacts": [
        str(p.relative_to(pathlib.Path.cwd()))
        for p in pathlib.Path("build").glob("**/Shared.framework")
    ],
}
(out / "summary.json").write_text(json.dumps(summary, indent=2))
print(json.dumps(summary, indent=2))
PY

if [[ "$MODE" == "macos" && "$LINK_STATUS" -ne 0 ]]; then
  exit "$LINK_STATUS"
fi

echo "Probe completed. Preserve compile-klib.log, link-framework.log, summary.json, and klib-inventory.json."

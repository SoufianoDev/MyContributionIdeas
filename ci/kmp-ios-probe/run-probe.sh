#!/usr/bin/env bash
set -uo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_DIR"

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
  echo "SOURCE_FILES"
  find src -type f -maxdepth 8 -print | sort
  if [[ "$MODE" == "macos" ]]; then
    xcode-select -p
    xcodebuild -version
    xcrun --sdk iphoneos --show-sdk-version
  fi
} >"$RESULTS_DIR/environment.log" 2>&1

set +e
gradle --no-daemon --console=plain --info --stacktrace --rerun-tasks clean compileKotlinIosArm64 \
  >"$RESULTS_DIR/compile-klib.log" 2>&1
COMPILE_STATUS=$?
set -e

find build -type f -printf '%P %s bytes\n' 2>/dev/null | sort >"$RESULTS_DIR/build-files-after-compile.txt" || true
find build -type f -name '*.klib' -print 2>/dev/null | sort >"$RESULTS_DIR/klib-paths.txt" || true

python3 - "$RESULTS_DIR" "$COMPILE_STATUS" <<'PY'
import json, pathlib, sys, zipfile
out = pathlib.Path(sys.argv[1])
status = int(sys.argv[2])
project = pathlib.Path.cwd()
klibs = sorted(pathlib.Path("build").rglob("*.klib")) if pathlib.Path("build").exists() else []
entries = []
for path in klibs:
    names = []
    try:
        with zipfile.ZipFile(path) as archive:
            names = archive.namelist()
    except Exception as exc:
        names = [f"INSPECTION_ERROR: {exc}"]
    llvm_entries = [name for name in names if name.lower().endswith((".bc", ".ll"))]
    entries.append({
        "path": str(path.relative_to(project)),
        "bytes": path.stat().st_size,
        "llvm_entries": llvm_entries[:100],
        "llvm_entry_count": len(llvm_entries),
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
gradle --no-daemon --console=plain --info --stacktrace --rerun-tasks linkDebugFrameworkIosArm64 \
  >"$RESULTS_DIR/link-framework.log" 2>&1
LINK_STATUS=$?
set -e

find build -type f -printf '%P %s bytes\n' 2>/dev/null | sort >"$RESULTS_DIR/build-files-after-link.txt" || true
find build -type d -name 'Shared.framework' -print 2>/dev/null | sort >"$RESULTS_DIR/framework-paths.txt" || true

python3 - "$MODE" "$COMPILE_STATUS" "$LINK_STATUS" "$RESULTS_DIR" <<'PY'
import json, pathlib, re, sys
mode, compile_status, link_status = sys.argv[1], int(sys.argv[2]), int(sys.argv[3])
out = pathlib.Path(sys.argv[4])
log = (out / "link-framework.log").read_text(errors="replace")
compile_log = (out / "compile-klib.log").read_text(errors="replace")
klib_data = json.loads((out / "klib-inventory.json").read_text())
host_block = bool(re.search(
    r"Target .*iosArm64.*not available for output kind.*(linux_x64|linux)",
    log, re.IGNORECASE | re.DOTALL
))
link_task_skipped = bool(re.search(r"> Task :linkDebugFrameworkIosArm64 SKIPPED", log))
compile_task_skipped = bool(re.search(r"> Task :compileKotlinIosArm64 SKIPPED", compile_log))
frameworks = [
    str(p.relative_to(pathlib.Path.cwd()))
    for p in pathlib.Path("build").rglob("Shared.framework")
] if pathlib.Path("build").exists() else []
if mode == "linux":
    classification = (
        "stock_host_gate_reproduced" if host_block else
        "gradle_framework_task_skipped" if link_task_skipped else
        "framework_output_found" if frameworks else
        "framework_link_failed_for_another_reason" if link_status != 0 else
        "framework_task_returned_zero_without_output"
    )
else:
    classification = (
        "macos_reference_framework_succeeded" if link_status == 0 and frameworks else
        "macos_framework_task_skipped" if link_task_skipped else
        "macos_reference_framework_failed_or_missing"
    )
summary = {
    "mode": mode,
    "compile_klib_exit": compile_status,
    "compile_task_skipped": compile_task_skipped,
    "klib_count": klib_data["klib_count"],
    "klib_inventory": klib_data["klibs"],
    "framework_link_exit": link_status,
    "framework_task_skipped": link_task_skipped,
    "explicit_linux_host_gate_detected": host_block,
    "classification": classification,
    "framework_artifacts": frameworks,
}
(out / "summary.json").write_text(json.dumps(summary, indent=2))
print(json.dumps(summary, indent=2))
PY

if [[ "$MODE" == "macos" ]]; then
  if [[ "$LINK_STATUS" -ne 0 || ! -s "$RESULTS_DIR/framework-paths.txt" ]]; then
    exit 1
  fi
fi

if [[ "$MODE" == "linux" && "$LINK_STATUS" -eq 0 && ! -s "$RESULTS_DIR/framework-paths.txt" ]]; then
  echo "Gradle returned success but no iOS framework was produced; inspect task skip/output evidence." >&2
fi

echo "Probe completed. Preserve full Gradle logs, source/build inventories, KLIB inventory, and summary."

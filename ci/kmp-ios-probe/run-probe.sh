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

python3 - "$RESULTS_DIR" "$COMPILE_STATUS" <<'PY'
import json, pathlib, sys
out = pathlib.Path(sys.argv[1])
status = int(sys.argv[2])
root = pathlib.Path("build")
packed = sorted(root.rglob("*.klib")) if root.exists() else []
unpacked = []
for manifest in sorted(root.rglob("manifest")) if root.exists() else []:
    base = manifest.parent
    if (base / "linkdata").is_dir() and (base / "ir").is_dir():
        files = sorted(p for p in base.rglob("*") if p.is_file())
        llvm = [p.relative_to(base).as_posix() for p in files if p.suffix.lower() in {".bc", ".ll"}]
        unpacked.append({
            "path": base.as_posix(),
            "manifest_bytes": manifest.stat().st_size,
            "file_count": len(files),
            "files": [{"path": p.relative_to(base).as_posix(), "bytes": p.stat().st_size} for p in files],
            "llvm_bitcode_or_ir_entries": llvm,
        })
(out / "klib-inventory.json").write_text(json.dumps({
    "compile_exit": status,
    "packed_klib_count": len(packed),
    "packed_klib_paths": [p.as_posix() for p in packed],
    "unpacked_klib_count": len(unpacked),
    "unpacked_klibs": unpacked,
}, indent=2))
PY

if [[ "$COMPILE_STATUS" -ne 0 ]]; then
  cat >"$RESULTS_DIR/summary.json" <<EOF
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

FORCED_STATUS=null
FORCED_HOST_GATE=false
if [[ "$MODE" == "linux" ]]; then
  set +e
  gradle --no-daemon --console=plain --info --stacktrace --rerun-tasks \
    -I "$SCRIPT_DIR/force-ios-link.init.gradle" linkDebugFrameworkIosArm64 \
    >"$RESULTS_DIR/forced-link-framework.log" 2>&1
  FORCED_STATUS=$?
  set -e
  if grep -Eqi 'Target .*iosArm64.*not available for output kind.*(linux_x64|linux)' "$RESULTS_DIR/forced-link-framework.log"; then
    FORCED_HOST_GATE=true
  fi
  find build -type d -name 'Shared.framework' -print 2>/dev/null | sort >"$RESULTS_DIR/forced-framework-paths.txt" || true
fi

python3 - "$MODE" "$COMPILE_STATUS" "$LINK_STATUS" "$FORCED_STATUS" "$FORCED_HOST_GATE" "$RESULTS_DIR" <<'PY'
import json, pathlib, re, sys
mode, compile_status, link_status = sys.argv[1], int(sys.argv[2]), int(sys.argv[3])
forced_status = None if sys.argv[4] == "null" else int(sys.argv[4])
forced_host_gate = sys.argv[5].lower() == "true"
out = pathlib.Path(sys.argv[6])
link_log = (out / "link-framework.log").read_text(errors="replace")
compile_log = (out / "compile-klib.log").read_text(errors="replace")
klib_data = json.loads((out / "klib-inventory.json").read_text())
host_block = bool(re.search(
    r"Target .*iosArm64.*not available for output kind.*(linux_x64|linux)",
    link_log, re.IGNORECASE | re.DOTALL
))
link_task_skipped = bool(re.search(r"> Task :linkDebugFrameworkIosArm64 SKIPPED", link_log))
compile_task_skipped = bool(re.search(r"> Task :compileKotlinIosArm64 SKIPPED", compile_log))
frameworks = sorted(
    p.as_posix() for p in pathlib.Path("build").rglob("Shared.framework")
) if pathlib.Path("build").exists() else []
forced_frameworks = []
if (out / "forced-framework-paths.txt").exists():
    forced_frameworks = [x for x in (out / "forced-framework-paths.txt").read_text().splitlines() if x]
if mode == "linux":
    classification = (
        "forced_compiler_host_gate_reproduced" if forced_host_gate else
        "forced_link_produced_framework" if forced_status == 0 and forced_frameworks else
        "forced_link_failed_for_another_reason" if forced_status not in (None, 0) else
        "gradle_link_task_skipped"
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
    "packed_klib_count": klib_data["packed_klib_count"],
    "unpacked_klib_count": klib_data["unpacked_klib_count"],
    "unpacked_klibs": klib_data["unpacked_klibs"],
    "framework_link_exit": link_status,
    "framework_task_skipped": link_task_skipped,
    "explicit_linux_host_gate_detected_in_normal_link": host_block,
    "forced_framework_link_exit": forced_status,
    "forced_compiler_host_gate_detected": forced_host_gate,
    "classification": classification,
    "framework_artifacts": frameworks,
    "forced_framework_artifacts": forced_frameworks,
}
(out / "summary.json").write_text(json.dumps(summary, indent=2))
print(json.dumps(summary, indent=2))
PY

if [[ "$MODE" == "macos" ]]; then
  if [[ "$LINK_STATUS" -ne 0 || ! -s "$RESULTS_DIR/framework-paths.txt" ]]; then
    exit 1
  fi
fi

echo "Probe completed. Preserve full Gradle logs, KLIB inventories, task-skip evidence, and summaries."

#!/usr/bin/env bash
set -Eeuo pipefail

ARTIFACTS=/artifacts
WORK=/work
RESEARCH=/probe
KOTLIN_REPO="$WORK/kotlin"
LLVM_ARCHIVE="$WORK/llvm-21-x86_64-linux-essentials-116.tar.gz"
MAC_ARCHIVE="$WORK/kotlin-native-prebuilt-macos-aarch64-2.4.21.tar.gz"
LLVM_URL="https://download.jetbrains.com/kotlin/native/resources/llvm/21-x86_64-linux/llvm-21-x86_64-linux-essentials-116.tar.gz"
MAC_URL="https://github.com/JetBrains/kotlin/releases/download/v2.4.21/kotlin-native-prebuilt-macos-aarch64-2.4.21.tar.gz"
LLVM_SHA="0b1f290214dd7ec20e2506210967e0ebd735cdefc3a3b4485bbccb439fa78e5b"
MAC_SHA="bf4edb526d91e17d0862102f69250525d788e79011f86c2c64362749adf260ae"

mkdir -p "$ARTIFACTS" "$WORK" "$GRADLE_USER_HOME" "$KONAN_DATA_DIR"
cat > "$GRADLE_USER_HOME/gradle.properties" <<'EOF'
org.gradle.java.installations.paths=/usr/lib/jvm/java-17-openjdk-amd64,/usr/lib/jvm/java-21-openjdk-amd64
EOF
exec > >(tee -a "$ARTIFACTS/run.log") 2>&1

echo "=== ENVIRONMENT ==="
date -u
uname -a
java -version
clang++ --version
cmake --version
df -h
free -h || true

download_verified() {
  local url="$1"
  local dest="$2"
  local sha="$3"
  if [[ ! -s "$dest" ]]; then
    curl --fail --location --retry 4 --retry-all-errors --connect-timeout 30 \
      --output "$dest" "$url"
  fi
  echo "$sha  $dest" | sha256sum --check -
  stat --printf='%n %s bytes\n' "$dest"
}

echo "=== VERIFIED INPUTS ==="
download_verified "$LLVM_URL" "$LLVM_ARCHIVE" "$LLVM_SHA"
download_verified "$MAC_URL" "$MAC_ARCHIVE" "$MAC_SHA"

mkdir -p "$WORK/llvm"
tar -xzf "$LLVM_ARCHIVE" -C "$WORK/llvm"
LLVM_CLANGXX="$(find "$WORK/llvm" -mindepth 1 -maxdepth 6 \( -type f -o -type l \) -path '*/bin/clang++' -print -quit)"
if [[ -z "$LLVM_CLANGXX" ]]; then
  echo "Could not locate clang++ (including symlinks) in the verified LLVM essentials archive" >&2
  find "$WORK/llvm" -maxdepth 6 -name 'clang*' -print | head -80 || true
  exit 20
fi
LLVM_HOME="$(dirname "$(dirname "$LLVM_CLANGXX")")"
"$LLVM_HOME/bin/clang++" --version
[[ "$("$LLVM_HOME/bin/clang++" --version | head -1)" == *"21.1.6"* ]] || {
  echo "Unexpected compiler version under $LLVM_HOME" >&2
  exit 21
}

mkdir -p "$WORK/ios-sdk-placeholder" "$WORK/apple-tools-placeholder" \
  "$ARTIFACTS/objects" "$ARTIFACTS/project-llvm-ir" "$ARTIFACTS/strace"

echo "=== EXTRACT IOS RUNTIME INPUTS FROM VERIFIED MACOS DISTRIBUTION ==="
python3 - "$MAC_ARCHIVE" "$WORK/ios-payload" <<'PY'
import pathlib, sys, tarfile
archive = pathlib.Path(sys.argv[1])
root = pathlib.Path(sys.argv[2])
native_count = 0
platform_klib_count = 0
with tarfile.open(archive, "r:gz") as tar:
    for member in tar:
        if not member.isfile():
            continue
        name = member.name
        native_marker = "/konan/targets/ios_arm64/native/"
        klib_marker = "/klib/platform/ios_arm64/"
        if native_marker in name:
            relative = name.split(native_marker, 1)[1]
            if not relative.endswith(".bc"):
                continue
            destination = root / "native" / relative
            native_count += 1
        elif klib_marker in name:
            relative = name.split(klib_marker, 1)[1]
            if not relative.endswith(".klib"):
                continue
            destination = root / "klib-platform" / relative
            platform_klib_count += 1
        else:
            continue
        if ".." in pathlib.PurePosixPath(relative).parts:
            raise RuntimeError(f"Unsafe archive path: {name}")
        destination.parent.mkdir(parents=True, exist_ok=True)
        source = tar.extractfile(member)
        if source is None:
            raise RuntimeError(f"Could not extract {name}")
        destination.write_bytes(source.read())
print(f"IOS_RUNTIME_BITCODE_FILES={native_count}")
print(f"IOS_PLATFORM_KLIB_FILES={platform_klib_count}")
if native_count == 0:
    raise SystemExit("No ios_arm64 runtime bitcode was found in the verified archive")
PY

echo "=== CLONE PINNED KOTLIN SOURCE ==="
git clone --depth 1 --branch v2.4.21 https://github.com/JetBrains/kotlin.git "$KOTLIN_REPO"
git -C "$KOTLIN_REPO" rev-parse HEAD | tee "$ARTIFACTS/kotlin-source-commit.txt"
echo "kotlin.native.enabled=true" > "$KOTLIN_REPO/local.properties"

echo "=== APPLY ISOLATED EXPERIMENTAL SOURCE PATCHES ==="
python3 - "$KOTLIN_REPO" "$LLVM_HOME" "$WORK" <<'PY'
import pathlib, sys

root = pathlib.Path(sys.argv[1])
llvm = pathlib.Path(sys.argv[2]).resolve()
work = pathlib.Path(sys.argv[3]).resolve()

def replace_once(path, old, new):
    file = root / path
    text = file.read_text()
    count = text.count(old)
    if count != 1:
        raise SystemExit(f"Expected exactly one patch match in {path}, found {count}")
    file.write_text(text.replace(old, new, 1))
    print(f"PATCHED {path}")

replace_once(
    "native/utils/src/org/jetbrains/kotlin/konan/target/HostManager.kt",
    "        LINUX_X64 to commonTargets,",
    "        LINUX_X64 to commonTargets + IOS_ARM64,"
)

apple = "native/utils/src/org/jetbrains/kotlin/konan/target/Apple.kt"
replace_once(
    apple,
    """    private val xcodePartsProvider by lazy {
        if (InternalServer.isAvailable) {""",
    """    private val xcodePartsProvider by lazy {
        if (HostManager.host.family == Family.LINUX && target == KonanTarget.IOS_ARM64) {
            XcodePartsProvider.LinuxExperiment(
                absolute(sdkDependency),
                absolute(toolchainDependency),
                absolute(xcodeAddonDependency)
            )
        } else if (InternalServer.isAvailable) {"""
)
replace_once(
    apple,
    """        XcodePartsProvider.InternalServer -> absolute(sdkDependency)
    }""",
    """        is XcodePartsProvider.LinuxExperiment -> provider.sysRoot
        XcodePartsProvider.InternalServer -> absolute(sdkDependency)
    }"""
)
replace_once(
    apple,
    '        XcodePartsProvider.InternalServer -> "' + chr(36) + '{absolute(toolchainDependency)}/usr"\n    }',
    """        is XcodePartsProvider.LinuxExperiment -> provider.toolchain
        XcodePartsProvider.InternalServer -> absolute(toolchainDependency)
    }"""
)
replace_once(
    apple,
    """        XcodePartsProvider.InternalServer -> absolute(additionalToolsDir)
    }""",
    """        is XcodePartsProvider.LinuxExperiment -> provider.additionalTools
        XcodePartsProvider.InternalServer -> absolute(additionalToolsDir)
    }"""
)
replace_once(
    apple,
    """        class Local(val xcode: Xcode) : XcodePartsProvider()
        object InternalServer : XcodePartsProvider()""",
    """        class Local(val xcode: Xcode) : XcodePartsProvider()
        data class LinuxExperiment(
            val sysRoot: String,
            val toolchain: String,
            val additionalTools: String
        ) : XcodePartsProvider()
        object InternalServer : XcodePartsProvider()"""
)

properties = root / "kotlin-native/konan/konan.properties"
append = f"""

# Experimental Linux-hosted ios_arm64 codegen probe only. These are not an Apple SDK/toolchain.
llvmHome.linux_x64 = {llvm}
targetToolchain.linux_x64-ios_arm64 = {llvm}
targetSysRoot.ios_arm64 = {work / "ios-sdk-placeholder"}
additionalToolsDir.linux_x64 = {work / "apple-tools-placeholder"}
"""
properties.write_text(properties.read_text() + append)
print("PATCHED kotlin-native/konan/konan.properties")

bitcode = "kotlin-native/backend.native/compiler/ir/backend.native/src/org/jetbrains/kotlin/backend/konan/BitcodeCompiler.kt"
replace_once(
    bitcode,
    """    fun makeObjectFile(bitcodeFile: File, objectFile: File) =
            when (val configurables = platform.configurables) {
                is ClangFlags -> clang(configurables, bitcodeFile, objectFile)
                else -> error("Unsupported configurables kind: ${configurables::class.simpleName}!")
            }""",
    """    fun makeObjectFile(bitcodeFile: File, objectFile: File) {
        when (val configurables = platform.configurables) {
            is ClangFlags -> clang(configurables, bitcodeFile, objectFile)
            else -> error("Unsupported configurables kind: ${configurables::class.simpleName}!")
        }
        val preserveDir = System.getenv("KONAN_PRESERVE_OBJECTS_DIR")
        if (!preserveDir.isNullOrBlank() && objectFile.isFile) {
            val destinationDir = File(preserveDir).apply { mkdirs() }
            val safeName = objectFile.absolutePath.replace(Regex("[^A-Za-z0-9_.-]"), "_")
            val destination = File(destinationDir, safeName)
            objectFile.copyTo(destination, overwrite = true)
            context.log("KONAN_PROBE_OBJECT_PRESERVED=" + destination.absolutePath)
        }
    }"""
)

linker = "kotlin-native/backend.native/compiler/ir/backend.native/src/org/jetbrains/kotlin/backend/konan/Linker.kt"
replace_once(
    linker,
    """internal fun runLinkerCommands(context: NativeBackendPhaseContext, commands: List<Command>, cachingInvolved: Boolean) = try {""",
    """internal fun runLinkerCommands(context: NativeBackendPhaseContext, commands: List<Command>, cachingInvolved: Boolean) =
    if (System.getenv("KONAN_PROBE_STOP_BEFORE_FINAL_LINK") == "1") {
        context.log("KONAN_PROBE_FINAL_LINK_SKIPPED commands=" + commands.size)
    } else try {"""
)
linker = "kotlin-native/backend.native/compiler/ir/backend.native/src/org/jetbrains/kotlin/backend/konan/driver/phases/Linker.kt"
replace_once(
    linker,
    "    runLinkerCommands(context, commands, cachingInvolved = !input.resolvedCacheBinaries.isEmpty())",
    """    if (System.getenv("KONAN_PROBE_STOP_BEFORE_FINAL_LINK") == "1") {
        context.log("KONAN_PROBE_FINAL_LINK_SKIPPED")
    } else {
        runLinkerCommands(context, commands, cachingInvolved = !input.resolvedCacheBinaries.isEmpty())
    }"""
)
PY

git -C "$KOTLIN_REPO" diff --check
git -C "$KOTLIN_REPO" diff > "$ARTIFACTS/kotlin-experimental-source-patch.diff"
sha256sum "$ARTIFACTS/kotlin-experimental-source-patch.diff" | tee "$ARTIFACTS/source-patch.sha256"

echo "=== BUILD TEMPORARY KOTLIN/NATIVE DISTRIBUTION ==="
set +e
(
  cd "$KOTLIN_REPO"
  ./gradlew --no-daemon --console=plain --stacktrace --max-workers=4 \
    -Dhttp.socketTimeout=120000 -Dhttp.connectionTimeout=120000 \
    :kotlin-native:dist
) > "$ARTIFACTS/build-patched-kotlin-native.log" 2>&1
BUILD_STATUS=$?
set -e
echo "PATCHED_KOTLIN_NATIVE_DIST_EXIT=$BUILD_STATUS"
if [[ "$BUILD_STATUS" -ne 0 ]]; then
  tail -n 160 "$ARTIFACTS/build-patched-kotlin-native.log" || true
  echo '{"classification":"patched_kotlin_native_distribution_build_failed"}' > "$ARTIFACTS/summary.json"
  exit "$BUILD_STATUS"
fi

KONANC="$(find "$KOTLIN_REPO" -type f -path '*/bin/konanc' -print -quit)"
if [[ -z "$KONANC" ]]; then
  echo "The source build succeeded but no bin/konanc was found" >&2
  exit 30
fi
KONAN_HOME="$(dirname "$(dirname "$KONANC")")"
echo "KONAN_HOME=$KONAN_HOME" | tee "$ARTIFACTS/konan-home.txt"
"$KONANC" -version | tee "$ARTIFACTS/patched-konanc-version.txt"

echo "=== INSTALL VERIFIED IOS RUNTIME INPUTS INTO TEMPORARY DIST ==="
mkdir -p "$KONAN_HOME/konan/targets/ios_arm64/native"
cp -a "$WORK/ios-payload/native/." "$KONAN_HOME/konan/targets/ios_arm64/native/"
if [[ -d "$WORK/ios-payload/klib-platform" ]]; then
  mkdir -p "$KONAN_HOME/klib/platform/ios_arm64"
  cp -a "$WORK/ios-payload/klib-platform/." "$KONAN_HOME/klib/platform/ios_arm64/"
fi
find "$KONAN_HOME/konan/targets/ios_arm64/native" -maxdepth 1 -type f -name '*.bc' \
  -printf '%f %s bytes\n' | sort > "$ARTIFACTS/ios-runtime-inventory.txt"
sha256sum "$KONAN_HOME/konan/targets/ios_arm64/native/"*.bc \
  > "$ARTIFACTS/ios-runtime-sha256.txt"

echo "=== CHECK PATCHED TARGET VISIBILITY ==="
set +e
"$KONANC" -list_targets > "$ARTIFACTS/patched-target-list.log" 2>&1
TARGET_LIST_STATUS=$?
set -e
echo "PATCHED_TARGET_LIST_EXIT=$TARGET_LIST_STATUS"
grep -n -E 'ios_arm64|linux_x64' "$ARTIFACTS/patched-target-list.log" || true

echo "=== CONFIGURE REAL KMP PROJECT ==="
PROJECT="$WORK/project"
rm -rf "$PROJECT"
cp -a "$RESEARCH/ci/kmp-ios-patched-compiler/project" "$PROJECT"
cat > "$PROJECT/gradle.properties" <<EOF
kotlin.native.home=$KONAN_HOME
kotlin.native.enableKlibsCrossCompilation=true
org.gradle.jvmargs=-Xmx4g -XX:MaxMetaspaceSize=1g -Dfile.encoding=UTF-8
EOF

echo "=== COMPILE REAL KMP KLIB ON LINUX ==="
set +e
"$KOTLIN_REPO/gradlew" --no-daemon --console=plain --stacktrace -p "$PROJECT" \
  compileKotlinIosArm64 > "$ARTIFACTS/compile-klib.log" 2>&1
KLIB_STATUS=$?
set -e
echo "KLIB_COMPILE_EXIT=$KLIB_STATUS"

echo "=== RUN ACTUAL IOS ARM64 SECOND-STAGE COMPILER ==="
LINK_STATUS=125
if [[ "$KLIB_STATUS" -eq 0 ]]; then
  set +e
  KONAN_PRESERVE_OBJECTS_DIR="$ARTIFACTS/objects" \
  KONAN_PROBE_STOP_BEFORE_FINAL_LINK=1 \
  KONAN_DATA_DIR="$KONAN_DATA_DIR" \
  strace -f -s 1024 \
    -e trace=openat,openat2,newfstatat,statx,access,readlink \
    -o "$ARTIFACTS/strace/linux-ios-codegen.strace" \
    "$KOTLIN_REPO/gradlew" --no-daemon --console=plain --info --stacktrace \
      -I "$RESEARCH/ci/kmp-ios-patched-compiler/force-link.init.gradle" \
      -p "$PROJECT" linkDebugExecutableIosArm64 \
      > "$ARTIFACTS/link-codegen.log" 2>&1
  LINK_STATUS=$?
  set -e
fi
echo "IOS_SECOND_STAGE_EXIT=$LINK_STATUS"

echo "=== INVENTORY LLVM IR AND OBJECT OUTPUTS ==="
find "$ARTIFACTS/project-llvm-ir" -type f -printf '%P %s bytes\n' 2>/dev/null | sort \
  > "$ARTIFACTS/llvm-ir-inventory.txt" || true
find "$ARTIFACTS/objects" -type f -printf '%P %s bytes\n' 2>/dev/null | sort \
  > "$ARTIFACTS/object-inventory.txt" || true
if find "$ARTIFACTS/objects" -type f -print -quit | grep -q .; then
  find "$ARTIFACTS/objects" -type f -print0 | xargs -0 sha256sum \
    > "$ARTIFACTS/object-sha256.txt"
  find "$ARTIFACTS/objects" -type f -print0 | xargs -0 file \
    > "$ARTIFACTS/object-file-types.txt"
fi

echo "=== INSPECT MACH-O OBJECT HEADERS ==="
python3 - "$ARTIFACTS/objects" "$ARTIFACTS/macho-inspection.json" <<'PY'
import json, pathlib, struct, sys

root = pathlib.Path(sys.argv[1])
out = pathlib.Path(sys.argv[2])
objects = []
for path in sorted(p for p in root.rglob("*") if p.is_file()):
    data = path.read_bytes()
    item = {"path": str(path), "bytes": len(data), "macho": False}
    if len(data) >= 32 and data[:4] == b"\xcf\xfa\xed\xfe":
        magic, cputype, cpusubtype, filetype, ncmds, sizeofcmds, flags, reserved = struct.unpack_from("<IiiIIIII", data, 0)
        item.update({
            "macho": True,
            "magic": hex(magic),
            "cputype": hex(cputype & 0xffffffff),
            "filetype": filetype,
            "ncmds": ncmds,
            "macho_arm64": (cputype & 0xffffffff) == 0x0100000c,
            "mh_object": filetype == 1,
        })
        offset = 32
        platform = None
        minos = None
        sdk = None
        symtab = None
        for _ in range(ncmds):
            if offset + 8 > len(data):
                break
            cmd, cmdsize = struct.unpack_from("<II", data, offset)
            if cmdsize < 8 or offset + cmdsize > len(data):
                break
            if cmd == 0x32 and cmdsize >= 24:
                _, _, platform, minos, sdk, ntools = struct.unpack_from("<IIIIII", data, offset)
            elif cmd == 0x25 and cmdsize >= 16:
                _, _, minos, sdk = struct.unpack_from("<IIII", data, offset)
                platform = 2
            elif cmd == 0x2 and cmdsize >= 24:
                symtab = struct.unpack_from("<IIIIII", data, offset)
            offset += cmdsize
        item["platform"] = platform
        item["minimum_os_raw"] = minos
        item["sdk_raw"] = sdk
        item["ios_platform"] = platform == 2
        item["minimum_os"] = (f"{minos >> 16}.{(minos >> 8) & 0xff}.{minos & 0xff}" if minos is not None else None)
        undefined = []
        if symtab:
            _, _, symoff, nsyms, stroff, strsize = symtab
            if symoff + nsyms * 16 <= len(data) and stroff + strsize <= len(data):
                for i in range(nsyms):
                    strx, n_type, n_sect, n_desc, n_value = struct.unpack_from("<IBBHQ", data, symoff + i * 16)
                    if (n_type & 0x0e) == 0 and 0 < strx < strsize:
                        end = data.find(b"\0", stroff + strx, stroff + strsize)
                        if end != -1:
                            undefined.append(data[stroff + strx:end].decode("utf-8", "replace"))
        item["undefined_symbol_count"] = len(undefined)
        item["undefined_symbols_sample"] = undefined[:80]
    objects.append(item)
out.write_text(json.dumps(objects, indent=2))
print(json.dumps(objects, indent=2))
PY

echo "=== PLACEHOLDER SYSROOT ACCESS TRACE ==="
grep -E '/work/ios-sdk-placeholder|/work/apple-tools-placeholder' \
  "$ARTIFACTS/strace/linux-ios-codegen.strace" \
  > "$ARTIFACTS/placeholder-path-accesses.txt" || true
wc -l "$ARTIFACTS/placeholder-path-accesses.txt"

echo "=== HASH COMPILER AND EVIDENCE ==="
find "$KONAN_HOME/konan/lib" -maxdepth 1 -type f -name '*.jar' -print0 \
  | xargs -0 -r sha256sum > "$ARTIFACTS/compiler-jar-sha256.txt"
sha256sum "$LLVM_ARCHIVE" "$MAC_ARCHIVE" > "$ARTIFACTS/input-archive-sha256.txt"

python3 - "$ARTIFACTS" "$BUILD_STATUS" "$KLIB_STATUS" "$LINK_STATUS" <<'PY'
import json, pathlib, sys
root = pathlib.Path(sys.argv[1])
build_status, klib_status, link_status = map(int, sys.argv[2:])
try:
    machos = json.loads((root / "macho-inspection.json").read_text())
except Exception:
    machos = []
marker = False
link_log = root / "link-codegen.log"
if link_log.exists():
    marker = "KONAN_PROBE_FINAL_LINK_SKIPPED" in link_log.read_text(errors="replace")
ir_files = (root / "llvm-ir-inventory.txt").read_text().splitlines() if (root / "llvm-ir-inventory.txt").exists() else []
valid_ios_arm64 = sum(
    1 for x in machos
    if x.get("macho_arm64") and x.get("mh_object") and x.get("ios_platform")
)
summary = {
    "kotlin_source_tag": "v2.4.21",
    "patched_distribution_build_exit": build_status,
    "klib_compile_exit": klib_status,
    "second_stage_exit": link_status,
    "final_link_guard_marker_seen": marker,
    "object_count_preserved": len(machos),
    "valid_ios_arm64_mh_object_count": valid_ios_arm64,
    "llvm_ir_files": ir_files,
    "objects": machos,
    "classification": (
        "real_project_ios_macho_objects_generated" if valid_ios_arm64 > 0 and marker else
        "codegen_or_object_emission_failed" if link_status != 0 else
        "no_verified_ios_object"
    ),
    "final_apple_link_attempted": False,
}
(root / "summary.json").write_text(json.dumps(summary, indent=2))
print(json.dumps(summary, indent=2))
PY

echo "=== COMPLETE ==="

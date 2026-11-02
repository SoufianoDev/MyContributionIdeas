# Kotlin/Native iOS host probe

This is a deliberately small, reproducible KMP project used to compare the stock Kotlin 2.4.21 iOS build boundary on Linux and macOS.

## What it tests

1. Compile a no-cinterop `iosArm64` source set to a KLIB with the stock Kotlin/Native 2.4.21 compiler.
2. Inspect the KLIB archive and record whether it contains LLVM bitcode or textual LLVM IR.
3. Attempt to link a static iOS framework.
4. On Linux, record whether the expected Kotlin/Native host/output-kind guard is the actual failure.
5. On macOS, use the installed Xcode toolchain as a reference and preserve the framework output when successful.

The Linux job runs inside a pinned Ubuntu 24.04 Docker image. The macOS job is a reference comparison only; it does not perform the Linux experiment.

## What it does not claim

- KLIB compilation is not LLVM project-code generation. Kotlin/Native's first compilation stage produces KLIBs; native link tasks perform the second-stage code generation and linking.
- A successful macOS build does not prove Linux support.
- This workflow does not bypass Kotlin/Native's host gate, patch the compiler, provide an Apple SDK to Linux, perform a final Linux iOS link, or run an iOS application.
- The workflow does not redistribute Apple SDK files.

## Reproduce locally

On Linux with Docker:

```bash
docker build -t kmp-ios-host-probe -f ci/kmp-ios-probe/Dockerfile .
mkdir -p artifacts/linux "$HOME/.konan"
docker run --rm \
  -v "$PWD/ci/kmp-ios-probe:/probe" \
  -v "$PWD/artifacts/linux:/artifacts" \
  -v "$HOME/.konan:/root/.konan" \
  -w /probe \
  kmp-ios-host-probe /probe/run-probe.sh linux
```

On macOS with JDK 21 and Gradle 9.7.0:

```bash
PROBE_RESULTS_DIR="$PWD/artifacts/macos" \
  bash ci/kmp-ios-probe/run-probe.sh macos
```

The workflow uploads logs, KLIB inventory, summary JSON, and any macOS framework output as GitHub Actions artifacts.

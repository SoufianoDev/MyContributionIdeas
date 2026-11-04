# Patched Kotlin/Native iOS codegen probe

This experiment lives only in the research branch. It clones Kotlin/Native tag v2.4.21 into a temporary CI workspace, applies a small host-enablement/toolchain-provider patch, builds a disposable compiler distribution, and attempts to generate a real iOS ARM64 object from a KMP project containing Kotlin source.

## Safety boundary

- No source changes are made to JetBrains' repository or to the research repository at runtime.
- The container installs JDK 17 and JDK 21 because Kotlin's Gradle build requests both toolchains; Gradle is explicitly pointed at both installations.
- The compiler source checkout and all modifications are disposable CI workspace data.
- The Apple SDK/sysroot path is an empty placeholder directory. It is not an SDK and contains no SDK headers, libraries, frameworks, or metadata.
- The experiment must stop before any final Apple linker command. A test-only guard in the temporary compiler source prevents LinkerPhase from invoking linker commands.
- The experiment does not run generated objects.
- The verified Kotlin LLVM 21.1.6 essentials package performs LLVM bitcode-to-object lowering.

## Patch scope

1. Add only IOS_ARM64 to the Linux x86_64 enabled target set.
2. Add an explicitly named experimental Linux path provider to AppleConfigurablesImpl using the supplied placeholder paths.
3. Add a test-only object-copy hook to preserve Clang-generated object files before Kotlin/Native temporary-file cleanup.
4. Add a fail-closed test-only guard around final LinkerPhase command execution.

These changes are not proposed as production-ready Kotlin patches. The workflow stores the complete source diff and hashes.

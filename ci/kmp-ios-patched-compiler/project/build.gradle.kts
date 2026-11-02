import org.jetbrains.kotlin.gradle.tasks.KotlinNativeLink

plugins {
    kotlin("multiplatform") version "2.4.21"
}

kotlin {
    iosArm64 {
        binaries {
            executable {
                entryPoint = "sample.main"
            }
        }
    }

    sourceSets {
        commonMain {
            dependencies {
            }
        }
    }
}

tasks.withType<KotlinNativeLink>().configureEach {
    if (name == "linkDebugExecutableIosArm64") {
        toolOptions.freeCompilerArgs.addAll(
            "-Xdisable-phases=Linker",
            "-Xsave-llvm-ir-after=Codegen",
            "-Xsave-llvm-ir-after=LinkBitcodeDependencies",
            "-Xsave-llvm-ir-directory=/artifacts/project-llvm-ir",
        )
    }
}

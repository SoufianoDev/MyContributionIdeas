plugins {
    kotlin("multiplatform") version "2.4.21"
}

kotlin {
    iosArm64 {
        binaries.framework {
            baseName = "Shared"
            isStatic = true
        }
    }

    sourceSets {
        commonMain {
            dependencies {
            }
        }
    }
}

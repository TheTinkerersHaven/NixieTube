pluginManagement {
    repositories {
        gradlePluginPortal()
        mavenCentral()
    }
    plugins {
        id("de.fayard.refreshVersions") version "0.60.6"
        id("org.jetbrains.dokka") version "2.2.0"
    }
}

plugins {
    id("de.fayard.refreshVersions")
}

dependencyResolutionManagement {
    repositories {
        google()
        mavenCentral()
        maven("https://jitpack.io")
    }
}

rootProject.name = "nixietube"

include(":core:innertube")
include(":core:player")
include(":core:artwork")
include(":desktop")

// Root build file: shared compiler config lives in module build files.
plugins {
    alias(libs.plugins.kotlin.jvm) apply false
    alias(libs.plugins.kotlin.serialization) apply false
    alias(libs.plugins.kotlin.compose) apply false
    alias(libs.plugins.compose.app) apply false
    id("org.jetbrains.dokka") version "2.2.0"
}

// Dokka: aggregate documentation from all subprojects into a single site.
dokka {
    dokkaPublications {
        html {
            moduleName.set(project.name)
            outputDirectory.set(layout.buildDirectory.dir("dokka/html"))
            includes.from("README.md")
        }
    }
    dokkaSourceSets {
        configureEach {
            jdkVersion.set(21)
        }
    }
}

// Aggregates subproject documentation into the root publication.
dependencies {
    dokka(project(":core:artwork"))
    dokka(project(":core:innertube"))
    dokka(project(":core:player"))
    dokka(project(":desktop"))
}

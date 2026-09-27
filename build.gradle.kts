// Root build file: shared compiler config lives in module build files.
plugins {
    alias(libs.plugins.kotlin.jvm) apply false
    alias(libs.plugins.kotlin.serialization) apply false
    alias(libs.plugins.kotlin.compose) apply false
    alias(libs.plugins.compose.app) apply false
    id("org.jetbrains.dokka") version "2.2.0"
    id("dev.detekt") version "2.0.0-alpha.6"
}

// Detekt analyzes only projects it is applied to, so apply it to every
// module (the root project alone has no sources to check).
subprojects {
    apply(plugin = "dev.detekt")
    configure<dev.detekt.gradle.extensions.DetektExtension> {
        config.setFrom(files("$rootDir/config/detekt/detekt.yml"))
        buildUponDefaultConfig.set(true)
        // Include experimental rules too: this is a findings hunt, not a gate.
        allRules.set(true)
        // Report without breaking the build; fix findings deliberately.
        ignoreFailures.set(true)
    }
    tasks.withType<dev.detekt.gradle.Detekt> {
        reports {
            html {
                required.set(true)
            }
        }
    }
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

plugins {
    alias(libs.plugins.kotlin.jvm)
    id("org.jetbrains.dokka")
    alias(libs.plugins.kotlin.serialization)
}

dokka {
    dokkaPublications {
        html {
            moduleName.set(project.name)
            moduleVersion.set(project.version.toString())
            outputDirectory.set(layout.buildDirectory.dir("dokka/html"))
            failOnWarning.set(false)
            suppressInheritedMembers.set(false)
            suppressObviousFunctions.set(true)
            offlineMode.set(false)
        }
    }
    dokkaSourceSets {
        configureEach {
            sourceRoots.from(file("src"))
            jdkVersion.set(21)
        }
    }
}

kotlin {
    jvmToolchain(21)
}
dependencies {
    implementation(project(":core:innertube"))
    implementation(libs.kotlinx.coroutines.core)
    implementation(libs.kotlinx.serialization.json)
}

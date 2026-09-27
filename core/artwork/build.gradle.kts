plugins {
    alias(libs.plugins.kotlin.jvm)
    id("org.jetbrains.dokka")
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
    implementation(libs.ktor.client.core)
    implementation(libs.ktor.client.cio)
    implementation(libs.kotlinx.coroutines.core)
}

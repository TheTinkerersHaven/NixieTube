plugins {
    alias(libs.plugins.kotlin.jvm)
    alias(libs.plugins.kotlin.serialization)
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
    implementation(libs.ktor.client.negotiation)
    implementation(libs.ktor.serialization.json)
    implementation(libs.kotlinx.coroutines.core)
    implementation(libs.kotlinx.serialization.json)
    // Stream-URL resolution (throttling-param decipher, itags). Pure Java, JVM-safe.
    implementation(libs.newpipe.extractor)
}

tasks.register<JavaExec>("smoke") {
    group = "verification"
    description = "Phase-0 spike: home, search, stream resolve against live InnerTube."
    classpath = sourceSets.main.get().runtimeClasspath
    mainClass.set("nixietube.innertube.SmokeKt")
}

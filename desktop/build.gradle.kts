
import org.gradle.api.DefaultTask
import org.gradle.api.tasks.TaskAction
import org.gradle.jvm.toolchain.JavaLanguageVersion
import org.gradle.jvm.toolchain.JavaToolchainService
import javax.inject.Inject

plugins {
    alias(libs.plugins.kotlin.jvm)
    alias(libs.plugins.kotlin.compose)
    alias(libs.plugins.compose.app)
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
base {
    archivesName.set("nixietube")
}
compose.desktop {
    application {
        mainClass = "nixietube.MainKt"
        jvmArgs("--add-opens=java.base/java.nio=ALL-UNNAMED")
    }
}
tasks.register<JavaExec>("artRepro") {
    group = "verification"
    description = "Isolated artwork crop repro on red background."
    classpath = sourceSets.main.get().runtimeClasspath
    mainClass.set("nixietube.ArtReproKt")
    jvmArgs("--add-opens=java.base/java.nio=ALL-UNNAMED")
}
dependencies {
    implementation(project(":core:innertube"))
    implementation(project(":core:player"))
    implementation(project(":core:artwork"))
    implementation(compose.desktop.currentOs)
    implementation(compose.material3)
    implementation(compose.components.resources)
    implementation(compose.materialIconsExtended)
    implementation(libs.kotlinx.coroutines.core)
    implementation(libs.kotlinx.coroutines.swing)
    implementation(libs.kotlinx.serialization.json)
    implementation(libs.ktor.client.core)
    implementation(libs.ktor.client.cio)
    implementation(libs.dbus.java.core)
    implementation(libs.dbus.java.transport.unixsocket)
}
// Trimmed runtime via the JDK's own jlink (no extra plugins): jdeps
// computes the exact java.* modules from the runtime classpath, then
// jlink links only those into build/jlink-runtime. Both tasks rebuild
// jars — close the app first (mmap), then:
//   ./gradlew :desktop:jlinkRuntime
//   build/jlink-runtime/bin/java -jar desktop/build/libs/nixietube.jar
// or ./gradlew :desktop:runTrimmed
tasks.register<JlinkRuntimeTask>("jlinkRuntime") {
    group = "distribution"
    description = "Links a trimmed Java runtime (close the app first: rebuilds jars)."
    dependsOn("jar")
}
abstract class JlinkRuntimeTask : DefaultTask() {
    @get:Inject
    abstract val toolchains: JavaToolchainService

    @TaskAction
    fun link() {
        val javaHome = toolchains.launcherFor {
            languageVersion.set(JavaLanguageVersion.of(21))
        }.get().metadata.installationPath.asFile
        val cpFiles = project.configurations.getByName("runtimeClasspath").files.toList()
        // Classpath mode: only our own jars are roots, everything else
        // goes on --class-path. Pointing jdeps at modular third-party
        // jars (okhttp/okio) forces full module-graph resolution, which
        // fails; classpath mode just reports the java.* modules used.
        val ourJars = cpFiles.filter {
            it.name.endsWith(".jar") && it.absolutePath.contains("/build/")
        }
        val depCp = (cpFiles - ourJars.toSet()).joinToString(File.pathSeparator) { it.absolutePath }
        val jdepsRoots = ourJars.map { it.absolutePath }.ifEmpty { cpFiles.map { it.absolutePath } }
        val jdepsProc = ProcessBuilder(
            listOf(
                File(javaHome, "bin/jdeps").absolutePath,
                "--print-module-deps", "-q", "--multi-release", "21",
                "--ignore-missing-deps",
                "--class-path", depCp,
            ) + jdepsRoots,
        ).redirectErrorStream(true).start()
        val jdepsText = jdepsProc.inputStream.bufferedReader().readText()
        jdepsProc.waitFor()
        val mods = jdepsText.lines()
            .map { it.trim() }
            .lastOrNull { it.isNotEmpty() && it.matches(Regex("[a-z0-9.,_ ]+")) }
            ?.split(",")?.map { it.trim() }?.filter { it.isNotEmpty() }?.toMutableSet()
            ?: throw GradleException("jdeps produced no module list:\n$jdepsText")
        // jdeps can't see dynamic needs: Unsafe/AWT hooks
        // (jdk.unsupported) and the TLS elliptic-curve provider, which
        // loads via ServiceLoader (jdk.crypto.ec — without it every
        // HTTPS handshake fails). Both always exist; including them
        // only costs bytes.
        mods += "jdk.unsupported"
        mods += "jdk.crypto.ec"
        // dbus-java loads com.sun.security.auth.module.UnixSystem
        // reflectively for session-bus auth; jdeps can't see it, and
        // without it MPRIS fails with NoClassDefFoundError.
        mods += "jdk.security.auth"
        val outDir = project.layout.buildDirectory.dir("jlink-runtime").get().asFile
        if (outDir.exists()) outDir.deleteRecursively()
        logger.lifecycle("jlink modules: ${mods.sorted().joinToString(",")}")
        val jlinkProc = ProcessBuilder(
            listOf(
                File(javaHome, "bin/jlink").absolutePath,
                "--module-path", File(javaHome, "jmods").absolutePath,
                "--add-modules", mods.sorted().joinToString(","),
                "--strip-debug", "--compress=2", "--no-header-files", "--no-man-pages",
                "--output", outDir.absolutePath,
            ),
        ).inheritIO().start()
        if (jlinkProc.waitFor() != 0) throw GradleException("jlink failed")
    }
}
tasks.register<Exec>("runTrimmed") {
    group = "distribution"
    description = "Runs the app on the trimmed jlink runtime (close the app first)."
    dependsOn("jlinkRuntime")
    // Plain Exec, not JavaExec: JavaExec validates its javaLauncher
    // toolchain against the executable, which a jlink image can never
    // satisfy.
    doFirst {
        val cp = sourceSets.main.get().runtimeClasspath.files
            .joinToString(File.pathSeparator) { it.absolutePath }
        val javaBin = layout.buildDirectory.dir("jlink-runtime/bin/java").get().asFile.absolutePath
        commandLine(
            javaBin,
            "--add-opens=java.base/java.nio=ALL-UNNAMED",
            "-cp", cp,
            "nixietube.MainKt",
        )
    }
}

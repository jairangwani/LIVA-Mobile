pluginManagement {
    repositories {
        google()
        mavenCentral()
        gradlePluginPortal()
    }
}

dependencyResolutionManagement {
    repositoriesMode.set(RepositoriesMode.FAIL_ON_PROJECT_REPOS)
    repositories {
        google()
        mavenCentral()
    }
}

rootProject.name = "LIVA Android Test"

// Include app module
include(":app")

// Include LIVA Animation SDK from parent directory
include(":liva-animation")
project(":liva-animation").projectDir = file("../liva-sdk-android/liva-animation")

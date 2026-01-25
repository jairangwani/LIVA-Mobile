# SDK Publishing Guide

How to publish LIVA Animation SDKs to package managers.

## iOS SDK

### Swift Package Manager

1. Ensure `Package.swift` is valid:
   ```bash
   cd liva-sdk-ios
   swift package dump-package
   ```

2. Tag release:
   ```bash
   git tag 1.0.0
   git push origin 1.0.0
   ```

3. Users add via Xcode or Package.swift:
   ```swift
   .package(url: "https://github.com/liva/liva-sdk-ios.git", from: "1.0.0")
   ```

### CocoaPods

1. Update `LIVAAnimation.podspec`:
   ```ruby
   Pod::Spec.new do |s|
     s.name         = "LIVAAnimation"
     s.version      = "1.0.0"
     s.summary      = "LIVA Avatar Animation SDK"
     s.homepage     = "https://github.com/liva/liva-sdk-ios"
     s.license      = { :type => "MIT", :file => "LICENSE" }
     s.author       = { "LIVA" => "dev@liva.com" }
     s.source       = { :git => "https://github.com/liva/liva-sdk-ios.git", :tag => s.version.to_s }
     s.ios.deployment_target = "15.0"
     s.swift_version = "5.9"
     s.source_files = "LIVAAnimation/Sources/**/*.swift"
     s.dependency "Socket.IO-Client-Swift", "~> 16.0"
   end
   ```

2. Validate:
   ```bash
   pod spec lint LIVAAnimation.podspec
   ```

3. Publish:
   ```bash
   pod trunk push LIVAAnimation.podspec
   ```

---

## Android SDK

### Maven Central

1. Configure signing in `gradle.properties`:
   ```properties
   signing.keyId=XXXXXXXX
   signing.password=password
   signing.secretKeyRingFile=/path/to/key.gpg

   mavenCentralUsername=username
   mavenCentralPassword=password
   ```

2. Update `build.gradle.kts`:
   ```kotlin
   publishing {
     publications {
       register<MavenPublication>("release") {
         groupId = "com.liva"
         artifactId = "animation"
         version = "1.0.0"

         pom {
           name.set("LIVA Animation SDK")
           description.set("Native Android SDK for LIVA avatar animations")
           url.set("https://github.com/liva/liva-sdk-android")
           licenses {
             license {
               name.set("MIT")
               url.set("https://opensource.org/licenses/MIT")
             }
           }
         }
       }
     }
   }
   ```

3. Publish:
   ```bash
   ./gradlew publishReleasePublicationToMavenCentralRepository
   ```

### JitPack (Alternative)

1. Ensure `build.gradle.kts` has proper group:
   ```kotlin
   group = "com.github.liva"
   version = "1.0.0"
   ```

2. Tag release on GitHub:
   ```bash
   git tag 1.0.0
   git push origin 1.0.0
   ```

3. Users add via JitPack:
   ```kotlin
   repositories {
     maven { url = uri("https://jitpack.io") }
   }

   dependencies {
     implementation("com.github.liva:liva-sdk-android:1.0.0")
   }
   ```

---

## Flutter App

### iOS App Store

1. Configure `ios/Runner.xcodeproj`:
   - Set bundle identifier: `com.liva.app`
   - Set version and build number
   - Configure signing

2. Build:
   ```bash
   flutter build ios --release
   ```

3. Upload via Xcode or Transporter

### Google Play Store

1. Configure `android/app/build.gradle.kts`:
   ```kotlin
   android {
     defaultConfig {
       applicationId = "com.liva.app"
       versionCode = 1
       versionName = "1.0.0"
     }
     signingConfigs {
       release {
         // Configure signing
       }
     }
   }
   ```

2. Build:
   ```bash
   flutter build appbundle --release
   ```

3. Upload via Google Play Console

---

## Version Numbering

Follow [Semantic Versioning](https://semver.org/):

- **MAJOR**: Breaking API changes
- **MINOR**: New features, backward compatible
- **PATCH**: Bug fixes, backward compatible

Example: `1.2.3`
- `1` = Major version
- `2` = Minor version
- `3` = Patch version

---

## Release Checklist

- [ ] Update version in all files
- [ ] Update CHANGELOG.md
- [ ] Run all tests
- [ ] Build release artifacts
- [ ] Tag release in git
- [ ] Publish to package managers
- [ ] Update documentation
- [ ] Announce release

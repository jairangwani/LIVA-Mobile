# LIVA Android Test App - Proguard Rules

# Keep LIVA SDK classes
-keep class com.liva.animation.** { *; }

# Keep Socket.IO
-keep class io.socket.** { *; }
-keepattributes Signature
-keepattributes *Annotation*

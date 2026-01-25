package com.liva.app

import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import com.liva.flutter.LIVAAnimationPlugin

class MainActivity : FlutterActivity() {
    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)

        // Register LIVA Animation plugin
        flutterEngine.plugins.add(LIVAAnimationPlugin())
    }
}

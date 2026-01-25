@echo off
REM LIVA Flutter App Setup Script for Windows
REM This script initializes the Flutter project and sets up native SDK integration

echo ======================================
echo LIVA Flutter App Setup
echo ======================================
echo.

REM Check if flutter is installed
where flutter >nul 2>&1
if %ERRORLEVEL% neq 0 (
    echo Error: Flutter is not installed or not in PATH
    echo Please install Flutter: https://flutter.dev/docs/get-started/install
    exit /b 1
)

echo Step 1: Checking Flutter installation...
flutter doctor

echo.
echo Step 2: Creating Flutter project structure...

REM Check if ios folder exists with content
if not exist "ios\Runner.xcodeproj\project.pbxproj" (
    echo Initializing Flutter platform folders...

    REM Create temp directory
    set TEMP_DIR=%TEMP%\liva_flutter_temp
    mkdir "%TEMP_DIR%" 2>nul

    REM Create new flutter project
    flutter create --org com.liva --project-name liva_app "%TEMP_DIR%\liva_app"

    REM Copy platform folders
    xcopy /E /I /Y "%TEMP_DIR%\liva_app\ios" "ios"
    xcopy /E /I /Y "%TEMP_DIR%\liva_app\android" "android"

    REM Clean up
    rmdir /S /Q "%TEMP_DIR%"

    echo Platform folders created.
)

echo.
echo Step 3: Installing dependencies...
flutter pub get

echo.
echo Step 4: Setting up Android...
if exist "android" (
    REM Check if settings.gradle needs updating
    findstr /C:"liva-animation" "android\settings.gradle" >nul 2>&1
    if %ERRORLEVEL% neq 0 (
        echo Adding LIVA SDK to Android settings.gradle...
        echo.>> "android\settings.gradle"
        echo // Include LIVA Animation SDK>> "android\settings.gradle"
        echo include ':liva-animation'>> "android\settings.gradle"
        echo project^(':liva-animation'^).projectDir = new File^('../../liva-sdk-android/liva-animation'^)>> "android\settings.gradle"
    )
)

echo.
echo Step 5: Creating plugin directory structure...
if not exist "android\app\src\main\kotlin\com\liva\flutter" (
    mkdir "android\app\src\main\kotlin\com\liva\flutter"
)

echo.
echo ======================================
echo Setup Complete!
echo ======================================
echo.
echo Next steps:
echo 1. Open ios/Runner.xcworkspace in Xcode (Mac only)
echo 2. Open android/ in Android Studio
echo 3. Run: flutter run
echo.
echo For Android, you may need to:
echo   - Sync Gradle in Android Studio
echo   - Set up an emulator or connect a device
echo.
echo For iOS development, you'll need a Mac with Xcode.
echo.
pause

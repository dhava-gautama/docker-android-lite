#!/bin/bash
set -e

if [ "$INSTALL_ANDROID_SDK" != "1" ]; then
    echo "[sdk] INSTALL_ANDROID_SDK=0, skipping SDK install"
    echo "[sdk] Mount SDK via volume at $ANDROID_SDK_ROOT"
    exit 0
fi

echo "[sdk] Installing Android SDK (API $API_LEVEL, $IMG_TYPE, $ARCHITECTURE)..."

# Download commandlinetools
wget -q "https://dl.google.com/android/repository/commandlinetools-linux-${CMD_LINE_VERSION}.zip" -P /tmp
mkdir -p "$ANDROID_SDK_ROOT/cmdline-tools/"
unzip -q -d "$ANDROID_SDK_ROOT/cmdline-tools/" "/tmp/commandlinetools-linux-${CMD_LINE_VERSION}.zip"
mv "$ANDROID_SDK_ROOT/cmdline-tools/cmdline-tools/" "$ANDROID_SDK_ROOT/cmdline-tools/tools/"
rm "/tmp/commandlinetools-linux-${CMD_LINE_VERSION}.zip"

# Accept licenses
yes | sdkmanager --licenses > /dev/null 2>&1

# Install exactly what's needed — nothing more
sdkmanager --install \
    "$PACKAGE_PATH" \
    "$ANDROID_PLATFORM_VERSION" \
    platform-tools \
    emulator

echo "[sdk] SDK installed successfully"

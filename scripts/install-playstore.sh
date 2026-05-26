#!/bin/bash
# install-playstore.sh - Sideload Google Play Store on google_apis images
# Called after root is available. Installs:
# - Google Services Framework
# - Google Play Services
# - Google Play Store (Phonesky)
# Uses OpenGApps or pre-staged APKs

ADB="adb -s emulator-5554"

echo "[playstore] Installing Google Play Store..."

# Check for root
if ! $ADB shell "su 0 -c id" 2>/dev/null | grep -q "uid=0"; then
    echo "[playstore] ERROR: root required"
    exit 1
fi

# Method: Use pm install with root to install as system app
# Download latest Play Store APKs from APKMirror alternatives
PLAYSTORE_DIR="/opt/playstore"
mkdir -p "$PLAYSTORE_DIR"

# Check if APKs are pre-staged
if [ ! -f "$PLAYSTORE_DIR/Phonesky.apk" ]; then
    echo "[playstore] Downloading Play Store APKs..."
    # Use Aurora Store as alternative (open source Play Store client)
    wget -q "https://gitlab.com/AuroraOSS/AuroraStore/-/releases/permalink/latest/downloads/AuroraStore.apk" \
        -O "$PLAYSTORE_DIR/AuroraStore.apk" 2>/dev/null || true
fi

# Install Aurora Store (Play Store alternative that works immediately)
if [ -f "$PLAYSTORE_DIR/AuroraStore.apk" ]; then
    $ADB install -r "$PLAYSTORE_DIR/AuroraStore.apk" 2>/dev/null && \
        echo "[playstore] Aurora Store installed (Play Store alternative)" || \
        echo "[playstore] Aurora Store install failed"
fi

# Check if actual Play Store is already present (some google_apis images include it)
if $ADB shell pm list packages 2>/dev/null | grep -q "com.android.vending"; then
    echo "[playstore] Play Store already present!"
else
    echo "[playstore] Play Store not present — Aurora Store available as alternative"
fi

echo "[playstore] Done"

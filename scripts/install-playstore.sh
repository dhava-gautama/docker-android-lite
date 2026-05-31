#!/bin/bash
# install-playstore.sh - Sideload Aurora Store on google_apis images
# Aurora Store is an open-source Play Store client that can install any Play Store app.
# Called after boot. Works with or without root.

ADB="adb -s emulator-5554"

echo "[playstore] Installing Aurora Store..."

# Try adb root first (google_apis userdebug images), fall back to su
if $ADB root 2>&1 | grep -q "restarting"; then
    sleep 2
fi

PLAYSTORE_DIR="/opt/playstore"
mkdir -p "$PLAYSTORE_DIR"

# Download Aurora Store if not pre-staged
if [ ! -f "$PLAYSTORE_DIR/AuroraStore.apk" ]; then
    echo "[playstore] Downloading Aurora Store..."
    wget -q "https://gitlab.com/AuroraOSS/AuroraStore/-/releases/permalink/latest/downloads/AuroraStore.apk" \
        -O "$PLAYSTORE_DIR/AuroraStore.apk" 2>/dev/null || true
fi

# Install Aurora Store (doesn't require root — regular pm install)
if [ -f "$PLAYSTORE_DIR/AuroraStore.apk" ]; then
    $ADB install -r "$PLAYSTORE_DIR/AuroraStore.apk" 2>/dev/null && \
        echo "[playstore] Aurora Store installed" || \
        echo "[playstore] Aurora Store install failed"
else
    echo "[playstore] Aurora Store APK not found, skipping"
fi

# Check if native Play Store is present (google_apis_playstore images)
if $ADB shell pm list packages 2>/dev/null | grep -q "com.android.vending"; then
    echo "[playstore] Native Play Store also present"
fi

$ADB unroot 2>/dev/null
echo "[playstore] Done"

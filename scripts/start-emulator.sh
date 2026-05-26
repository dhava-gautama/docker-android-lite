#!/bin/bash
# No set -e — pkill/cleanup commands may fail harmlessly

# ============================================================
# docker-android-lite entrypoint
# Minimal Android emulator with direct exec (no supervisord)
# ============================================================

export USER=root

OPT_MEMORY=${MEMORY:-4096}
OPT_CORES=${CORES:-2}
OPT_DEVICE=${DEVICE_ID:-pixel}
EMULATOR_CONSOLE_PORT=5554
ADB_PORT=5555

# --- GPU mode setup (must happen before emulator starts) ---
if [ "$GPU_ACCELERATED" = "true" ]; then
    export DISPLAY=":0.0"
    export GPU_MODE="host"
    Xvfb "$DISPLAY" -screen 0 1920x1080x16 -nolisten tcp &
    sleep 2
elif [ "${HEADLESS:-true}" != "true" ]; then
    export DISPLAY=":0.0"
    export GPU_MODE="swiftshader_indirect"
    Xvfb "$DISPLAY" -screen 0 1920x1080x16 -nolisten tcp &
    sleep 2
else
    export GPU_MODE="swiftshader_indirect"
fi

echo "============================================"
echo " docker-android-lite"
echo " API: $API_LEVEL | Device: $OPT_DEVICE"
echo " Memory: ${OPT_MEMORY}MB | Cores: $OPT_CORES"
echo " GPU: $GPU_MODE | Headless: ${HEADLESS:-true}"
echo "============================================"

# --- ADB server on all interfaces ---
# Disable USB monitoring (prevents Netlink SUBSYSTEM warnings in Docker)
# ADB_USB=0 tells adb to skip USB device scanning entirely
export ADB_USB=0
export ADB_MDNS_AUTO_CONNECT=0
adb -a -P 5037 server nodaemon 2>&1 | grep -v "Netlink: SUBSYSTEM" &

# --- socat port forwarding: container IP → localhost ---
LOCAL_IP=$(ip addr list eth0 2>/dev/null | grep "inet " | cut -d' ' -f6 | cut -d/ -f1)
if [ -n "$LOCAL_IP" ]; then
    socat tcp-listen:"$EMULATOR_CONSOLE_PORT",bind="$LOCAL_IP",fork tcp:127.0.0.1:"$EMULATOR_CONSOLE_PORT" &
    socat tcp-listen:"$ADB_PORT",bind="$LOCAL_IP",fork tcp:127.0.0.1:"$ADB_PORT" &
fi

# --- Suppress emulator warnings ---
# Create missing ini file to suppress "Failed to process .ini file" warning
mkdir -p /root/.android
touch /root/.android/emu-update-last-check.ini
# Create avd running dir to suppress "Using fallback path" warning
mkdir -p /root/.android/avd/running

# --- Clean stale locks from crashed runs ---
rm -f "$ANDROID_AVD_HOME/android.avd/"*.lock 2>/dev/null
pkill -9 -f "qemu-system" 2>/dev/null; sleep 1

# --- Create AVD if not exists ---
AVD_EXISTS=$(avdmanager list avd 2>/dev/null | grep -c "Name: android" || true)
if [ "$AVD_EXISTS" -ge 1 ]; then
    echo "[emu] Using existing AVD"
else
    echo "[emu] Creating AVD (device: $OPT_DEVICE, ABI: $ABI)..."
    echo no | avdmanager create avd \
        --force --name android --abi "$ABI" \
        --package "$PACKAGE_PATH" --device "$OPT_DEVICE"
fi

# --- Build emulator flags ---
EMU_FLAGS="-avd android"
EMU_FLAGS="$EMU_FLAGS -gpu $GPU_MODE"
EMU_FLAGS="$EMU_FLAGS -memory $OPT_MEMORY"
EMU_FLAGS="$EMU_FLAGS -cores $OPT_CORES"
EMU_FLAGS="$EMU_FLAGS -no-boot-anim"
EMU_FLAGS="$EMU_FLAGS -no-snapshot"
EMU_FLAGS="$EMU_FLAGS -skip-adb-auth"
EMU_FLAGS="$EMU_FLAGS -ranchu"
# Disable ADB authentication for external connections
EMU_FLAGS="$EMU_FLAGS -prop qemu.adb.secure=0"
# Disable modem simulator to suppress IPv6 resolution errors
EMU_FLAGS="$EMU_FLAGS -no-sim"

if [ "${HEADLESS:-true}" = "true" ]; then
    EMU_FLAGS="$EMU_FLAGS -no-window -no-audio"
fi

# Add user extra flags
EMU_FLAGS="$EMU_FLAGS $EXTRA_FLAGS"

# --- Wait for boot in background ---
(
    adb wait-for-device
    echo "[emu] Device connected, waiting for boot..."
    BOOT_TIMEOUT=300
    ELAPSED=0
    while [ $ELAPSED -lt $BOOT_TIMEOUT ]; do
        BOOT=$(adb shell getprop sys.boot_completed 2>/dev/null | tr -d '\r')
        if [ "$BOOT" = "1" ]; then
            echo "[emu] Boot completed in ${ELAPSED}s"

            # Post-boot optimizations
            adb shell settings put global window_animation_scale 0 2>/dev/null
            adb shell settings put global transition_animation_scale 0 2>/dev/null
            adb shell settings put global animator_duration_scale 0 2>/dev/null

            if [ "${HEADLESS:-true}" = "true" ]; then
                adb shell settings put system screen_off_timeout 15000 2>/dev/null
                adb shell settings put global low_power 1 2>/dev/null
                adb shell input keyevent KEYCODE_POWER 2>/dev/null
                echo "[emu] Headless optimizations applied"
            fi

            echo "[emu] Ready — ADB: adb connect <host>:5555"
            echo "[emu] Ready — scrcpy: scrcpy -s <host>:5555"

            # --- Pro features (run sequentially after boot) ---
            if [ "${ROOTED:-false}" = "true" ] && [ -f /opt/scripts/magisk-first-boot.sh ]; then
                RAMDISK="$ANDROID_SDK_ROOT/system-images/android-${API_LEVEL}/${ABI%/*}/${ARCHITECTURE}/ramdisk.img"
                echo "[emu] Running Magisk root setup..."
                /opt/scripts/magisk-first-boot.sh "$RAMDISK"
            fi

            if [ -f /opt/scripts/anti-emu.sh ]; then
                echo "[emu] Running anti-emu..."
                /opt/scripts/anti-emu.sh
            fi

            if [ -f /opt/scripts/install-playstore.sh ]; then
                echo "[emu] Installing Play Store..."
                /opt/scripts/install-playstore.sh
            fi

            if [ "${SSLBYPASS:-false}" = "true" ] && [ -f /opt/scripts/ssl-bypass.sh ]; then
                echo "[emu] Running SSL bypass..."
                /opt/scripts/ssl-bypass.sh &
            fi
            break
        fi
        sleep 5
        ELAPSED=$((ELAPSED + 5))
    done
    if [ $ELAPSED -ge $BOOT_TIMEOUT ]; then
        echo "[emu] WARNING: Boot did not complete within ${BOOT_TIMEOUT}s"
    fi
) &

# --- Launch emulator (child process, restartable for Magisk rootAVD cold boot) ---
echo "[emu] Starting emulator..."
while true; do
    emulator $EMU_FLAGS 2> >(grep -v \
        -e "cannnot unmap ptr" \
        -e "Could not open libX11" \
        -e "Basic token auth" \
        -e "Using fallback path" \
        -e "Overwriting existing" \
        -e "Netsim Wifi.*CANCELLED" \
        -e "character device modem" \
        -e "ACTION REQUIRED" \
        >&2)
    EXIT_CODE=$?
    # If a restart marker exists (set by magisk-first-boot.sh), restart the emulator
    if [ -f /tmp/.emu_restart ]; then
        rm -f /tmp/.emu_restart
        rm -f "$ANDROID_AVD_HOME/android.avd/"*.lock 2>/dev/null
        echo "[emu] Restarting emulator (Magisk cold boot)..."
        sleep 2
        continue
    fi
    echo "[emu] Emulator exited with code $EXIT_CODE"
    break
done

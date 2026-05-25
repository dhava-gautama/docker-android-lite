#!/bin/bash
set -e

# ============================================================
# docker-android-lite entrypoint
# Minimal Android emulator with direct exec (no supervisord)
# ============================================================

OPT_MEMORY=${MEMORY:-4096}
OPT_CORES=${CORES:-2}
OPT_DEVICE=${DEVICE_ID:-pixel}
EMULATOR_CONSOLE_PORT=5554
ADB_PORT=5555

echo "============================================"
echo " docker-android-lite"
echo " API: $API_LEVEL | Device: $OPT_DEVICE"
echo " Memory: ${OPT_MEMORY}MB | Cores: $OPT_CORES"
echo " GPU: $GPU_MODE"
echo "============================================"

# --- ADB server on all interfaces ---
adb -a -P 5037 server nodaemon &

# --- socat port forwarding: container IP → localhost ---
LOCAL_IP=$(ip addr list eth0 2>/dev/null | grep "inet " | cut -d' ' -f6 | cut -d/ -f1)
if [ -n "$LOCAL_IP" ]; then
    socat tcp-listen:"$EMULATOR_CONSOLE_PORT",bind="$LOCAL_IP",fork tcp:127.0.0.1:"$EMULATOR_CONSOLE_PORT" &
    socat tcp-listen:"$ADB_PORT",bind="$LOCAL_IP",fork tcp:127.0.0.1:"$ADB_PORT" &
fi

# --- Create AVD if not exists ---
AVD_EXISTS=$(avdmanager list avd 2>/dev/null | grep -c "Name: android" || true)
if [ "$AVD_EXISTS" -ge 1 ]; then
    echo "[emu] Using existing AVD"
    # Clean stale locks from crashed runs
    rm -f "$ANDROID_AVD_HOME/android.avd/"*.lock 2>/dev/null
else
    echo "[emu] Creating AVD (device: $OPT_DEVICE, ABI: $ABI)..."
    echo no | avdmanager create avd \
        --force --name android --abi "$ABI" \
        --package "$PACKAGE_PATH" --device "$OPT_DEVICE"
fi

# --- GPU mode ---
if [ "$GPU_ACCELERATED" = "true" ]; then
    export DISPLAY=":0.0"
    export GPU_MODE="host"
    Xvfb "$DISPLAY" -screen 0 1920x1080x16 -nolisten tcp &
    echo "[emu] GPU: host (hardware accelerated)"
else
    export GPU_MODE="swiftshader_indirect"
    echo "[emu] GPU: swiftshader (software rendering)"
fi

# --- Headless optimizations ---
if [ "${HEADLESS:-true}" = "true" ]; then
    WINDOW_FLAG="-no-window"
    AUDIO_FLAG="-no-audio"
else
    WINDOW_FLAG=""
    AUDIO_FLAG=""
    # Start Xvfb for display if not GPU mode
    if [ "$GPU_ACCELERATED" != "true" ]; then
        export DISPLAY=":0.0"
        Xvfb "$DISPLAY" -screen 0 1920x1080x16 -nolisten tcp &
    fi
fi

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
            if [ "${HEADLESS:-true}" = "true" ]; then
                adb shell settings put system screen_off_timeout 15000 2>/dev/null
                adb shell settings put global window_animation_scale 0 2>/dev/null
                adb shell settings put global transition_animation_scale 0 2>/dev/null
                adb shell settings put global animator_duration_scale 0 2>/dev/null
                adb shell settings put global low_power 1 2>/dev/null
                adb shell input keyevent KEYCODE_POWER 2>/dev/null
                echo "[emu] Headless optimizations applied"
            fi

            # Disable animations for all modes
            adb shell settings put global window_animation_scale 0 2>/dev/null
            adb shell settings put global transition_animation_scale 0 2>/dev/null
            adb shell settings put global animator_duration_scale 0 2>/dev/null

            echo "[emu] Ready — ADB: adb connect <host>:5555"
            echo "[emu] Ready — scrcpy: scrcpy -s <host>:5555"
            break
        fi
        sleep 5
        ELAPSED=$((ELAPSED + 5))
    done
    if [ $ELAPSED -ge $BOOT_TIMEOUT ]; then
        echo "[emu] WARNING: Boot did not complete within ${BOOT_TIMEOUT}s"
    fi
) &

# --- Launch emulator (foreground, PID 1 via exec) ---
echo "[emu] Starting emulator..."
exec emulator \
    -avd android \
    -gpu "$GPU_MODE" \
    -memory "$OPT_MEMORY" \
    -cores "$OPT_CORES" \
    -no-boot-anim \
    -no-snapshot \
    $WINDOW_FLAG \
    $AUDIO_FLAG \
    $EXTRA_FLAGS

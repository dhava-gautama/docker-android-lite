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

# --- socat port forwarding: container IP → localhost (delayed until emulator binds) ---
LOCAL_IP=$(ip addr list eth0 2>/dev/null | grep "inet " | cut -d' ' -f6 | cut -d/ -f1)
if [ -n "$LOCAL_IP" ]; then
    (
        # Wait for emulator to bind ports before forwarding
        for i in $(seq 1 30); do
            ss -tln 2>/dev/null | grep -q ":$ADB_PORT " && break
            sleep 1
        done
        socat tcp-listen:"$EMULATOR_CONSOLE_PORT",bind="$LOCAL_IP",fork tcp:127.0.0.1:"$EMULATOR_CONSOLE_PORT" &
        socat tcp-listen:"$ADB_PORT",bind="$LOCAL_IP",fork tcp:127.0.0.1:"$ADB_PORT" &
    ) &
fi

# --- Suppress emulator warnings ---
# Create missing ini file to suppress "Failed to process .ini file" warning
mkdir -p /root/.android
touch /root/.android/emu-update-last-check.ini
# Create avd running dir to suppress "Using fallback path" warning
mkdir -p /root/.android/avd/running
# Create discovery dir used by emulator registration (suppresses fallback warning)
DISCOVERY_DIR="${ANDROID_SDK_ROOT}/emulator/discovery"
mkdir -p "$DISCOVERY_DIR"
export ANDROID_EMULATOR_DISCOVERY_DIR="$DISCOVERY_DIR"

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
# Suppress metrics warning banner
EMU_FLAGS="$EMU_FLAGS -no-metrics"
# Disable gRPC (suppresses jwt token + android-studio auth warnings)
EMU_FLAGS="$EMU_FLAGS -no-grpc"

if [ "${HEADLESS:-true}" = "true" ]; then
    EMU_FLAGS="$EMU_FLAGS -no-window -no-audio"
    # Disable unnecessary hardware emulation in headless mode
    EMU_FLAGS="$EMU_FLAGS -no-camera -no-gnss"
    EMU_FLAGS="$EMU_FLAGS -screen no-touch"
    EMU_FLAGS="$EMU_FLAGS -skin 480x800"
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
                adb shell settings put system screen_off_timeout 1000 2>/dev/null
                adb shell settings put global low_power 1 2>/dev/null
                adb shell settings put system screen_brightness 0 2>/dev/null
                adb shell settings put system accelerometer_rotation 0 2>/dev/null
                adb shell settings put global auto_sync 0 2>/dev/null
                adb shell settings put secure location_mode 0 2>/dev/null
                # Shrink display buffer
                adb shell wm size 480x800 2>/dev/null
                adb shell wm density 160 2>/dev/null
                # --- Disable + force-stop Google bloat ---
                for pkg in com.google.android.gms com.google.android.gsf \
                    com.google.android.googlequicksearchbox com.google.android.apps.wellbeing \
                    com.google.android.as com.google.android.apps.photos \
                    com.google.android.youtube com.google.android.apps.youtube.music \
                    com.google.android.apps.maps com.google.android.gm \
                    com.google.android.apps.docs com.google.android.calendar \
                    com.google.android.apps.messaging com.google.android.dialer \
                    com.google.android.contacts com.google.android.inputmethod.latin \
                    com.google.android.tts com.google.android.apps.nexuslauncher \
                    com.google.android.marvin.talkback com.google.android.apps.wallpaper \
                    com.google.android.projection.gearhead com.android.camera2; do
                    adb shell pm disable-user "$pkg" 2>/dev/null
                done

                # --- Disable + kill unnecessary processes ---
                # Use adb root if available (google_apis images)
                adb root 2>/dev/null; sleep 2
                IS_ROOT=$(adb shell id 2>/dev/null | grep -c "uid=0")

                # Packages safe to disable in headless mode
                KILL_PKGS="com.android.systemui com.android.settings
                    com.android.phone com.google.android.bluetooth
                    com.google.android.settings.intelligence
                    com.google.android.cellbroadcastreceiver
                    com.google.android.devicelockcontroller
                    com.google.android.partnersetup com.google.android.rkpdapp
                    com.google.android.configupdater
                    com.google.android.healthconnect.controller
                    com.google.android.onetimeinitializer
                    com.google.android.permissioncontroller
                    com.google.android.ext.services
                    com.android.imsserviceentitlement com.android.printspooler
                    com.android.traceur com.android.emergency
                    com.android.providers.calendar com.android.managedprovisioning
                    com.android.emulator.multidisplay com.android.localtransport
                    com.android.dynsystem com.android.keychain com.android.se
                    com.android.externalstorage android.process.media
                    android.process.acore com.google.android.providers.media.module"

                for pkg in $KILL_PKGS; do
                    if [ "$IS_ROOT" = "1" ]; then
                        adb shell pm disable "$pkg" 2>/dev/null
                    else
                        adb shell pm disable-user "$pkg" 2>/dev/null
                    fi
                    adb shell am force-stop "$pkg" 2>/dev/null
                done

                # Trim cached processes aggressively
                adb shell settings put global activity_manager_constants max_cached_processes=4 2>/dev/null
                adb shell am kill-all 2>/dev/null
                # Drop page cache to free kernel memory
                adb shell "echo 3 > /proc/sys/vm/drop_caches" 2>/dev/null

                # Force doze mode for near-zero idle CPU
                adb shell dumpsys deviceidle enable all 2>/dev/null
                adb shell dumpsys deviceidle force-idle 2>/dev/null
                # Restrict background network
                adb shell cmd netpolicy set restrict-background true 2>/dev/null
                # Screen off
                adb shell input keyevent KEYCODE_POWER 2>/dev/null
                echo "[emu] Headless optimizations applied (bloat killed + doze)"
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
    emulator $EMU_FLAGS
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

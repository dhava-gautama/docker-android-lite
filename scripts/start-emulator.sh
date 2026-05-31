#!/bin/bash
# No set -e — pkill/cleanup commands may fail harmlessly

# ============================================================
# docker-android-lite entrypoint
# Supports single or multiple emulators (EMULATOR_COUNT)
# ============================================================

emit_state() { echo "{\"type\":\"state-update\",\"value\":\"$1\",\"instance\":\"${2:-0}\"}"; }

export USER=root
export ANDROID_EMULATOR_WAIT_TIME_BEFORE_KILL=${ANDROID_EMULATOR_WAIT_TIME_BEFORE_KILL:-10}

OPT_MEMORY=${MEMORY:-4096}
OPT_CORES=${CORES:-2}
OPT_DEVICE=${DEVICE_ID:-pixel}
EMULATOR_COUNT=${EMULATOR_COUNT:-1}

# --- GPU mode setup ---
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

emit_state "ANDROID_STARTING"
echo "============================================"
echo " docker-android-lite"
echo " API: $API_LEVEL | Device: $OPT_DEVICE"
echo " Memory: ${OPT_MEMORY}MB | Cores: $OPT_CORES"
echo " Instances: $EMULATOR_COUNT"
echo " GPU: $GPU_MODE | Headless: ${HEADLESS:-true}"
echo "============================================"

# --- ADB server on all interfaces ---
export ADB_USB=0
export ADB_MDNS_AUTO_CONNECT=0
adb -a -P 5037 server nodaemon 2>&1 | grep -v "Netlink: SUBSYSTEM" &

# --- Suppress emulator warnings + apply advanced features ---
mkdir -p /root/.android
touch /root/.android/emu-update-last-check.ini
cp /opt/scripts/advancedFeatures.ini /root/.android/advancedFeatures.ini 2>/dev/null
mkdir -p /root/.android/avd/running
DISCOVERY_DIR="${ANDROID_SDK_ROOT}/emulator/discovery"
mkdir -p "$DISCOVERY_DIR"
export ANDROID_EMULATOR_DISCOVERY_DIR="$DISCOVERY_DIR"

# --- Clean stale locks from ALL AVDs ---
rm -f "$ANDROID_AVD_HOME/"*.avd/*.lock 2>/dev/null
pkill -9 -f "qemu-system" 2>/dev/null; sleep 1

# ============================================================
# Create AVDs (one per instance)
# ============================================================
for IDX in $(seq 1 "$EMULATOR_COUNT"); do
    if [ "$EMULATOR_COUNT" -eq 1 ]; then
        AVD_NAME="android"
    else
        AVD_NAME="android-${IDX}"
    fi
    AVD_EXISTS=$(avdmanager list avd 2>/dev/null | grep -c "Name: ${AVD_NAME}" || true)
    if [ "$AVD_EXISTS" -ge 1 ]; then
        echo "[emu-${IDX}] Using existing AVD: ${AVD_NAME}"
    else
        echo "[emu-${IDX}] Creating AVD: ${AVD_NAME} (device: $OPT_DEVICE, ABI: $ABI)"
        echo no | avdmanager create avd \
            --force --name "$AVD_NAME" --abi "$ABI" \
            --package "$PACKAGE_PATH" --device "$OPT_DEVICE"
    fi

    # Disable sensors in AVD config (once, on first boot)
    AVD_CONFIG="$ANDROID_AVD_HOME/${AVD_NAME}.avd/config.ini"
    if [ -f "$AVD_CONFIG" ] && grep -q "hw.sensors.proximity = yes" "$AVD_CONFIG" 2>/dev/null; then
        for sensor in gyroscope_uncalibrated humidity light magnetic_field \
            magnetic_field_uncalibrated orientation pressure proximity temperature; do
            sed -i "s/hw.sensors.$sensor = yes/hw.sensors.$sensor = no/" "$AVD_CONFIG" 2>/dev/null
        done
        sed -i "s/hw.audioInput = yes/hw.audioInput = no/" "$AVD_CONFIG" 2>/dev/null
        sed -i "s/hw.audioOutput = yes/hw.audioOutput = no/" "$AVD_CONFIG" 2>/dev/null
        sed -i "s/hw.gps = yes/hw.gps = no/" "$AVD_CONFIG" 2>/dev/null
        sed -i "s/hw.camera.back = emulated/hw.camera.back = none/" "$AVD_CONFIG" 2>/dev/null
        echo "hw.keyboard = yes" >> "$AVD_CONFIG"
        echo "[emu-${IDX}] Disabled unused sensors/audio/GPS"
    fi
done

# ============================================================
# Build common emulator flags (per-instance AVD name + port added in launch loop)
# ============================================================
BASE_FLAGS=""
BASE_FLAGS="$BASE_FLAGS -gpu $GPU_MODE"
BASE_FLAGS="$BASE_FLAGS -memory $OPT_MEMORY"
BASE_FLAGS="$BASE_FLAGS -cores $OPT_CORES"
BASE_FLAGS="$BASE_FLAGS -accel on"
BASE_FLAGS="$BASE_FLAGS -no-boot-anim"
BASE_FLAGS="$BASE_FLAGS -no-snapstorage"
BASE_FLAGS="$BASE_FLAGS -skip-adb-auth"
BASE_FLAGS="$BASE_FLAGS -no-sim"
BASE_FLAGS="$BASE_FLAGS -no-metrics"
BASE_FLAGS="$BASE_FLAGS -no-passive-gps"
BASE_FLAGS="$BASE_FLAGS -no-cache"
BASE_FLAGS="$BASE_FLAGS -crash-report-mode disabled"
BASE_FLAGS="$BASE_FLAGS -detect-image-hang"
BASE_FLAGS="$BASE_FLAGS -prop qemu.adb.secure=0"
BASE_FLAGS="$BASE_FLAGS -prop ro.setupwizard.mode=DISABLED"
BASE_FLAGS="$BASE_FLAGS -prop ro.config.low_ram=true"

if [ "${HEADLESS:-true}" = "true" ]; then
    BASE_FLAGS="$BASE_FLAGS -no-window -no-qt -no-audio -lowram"
    BASE_FLAGS="$BASE_FLAGS -camera-back none -camera-front none"
    BASE_FLAGS="$BASE_FLAGS -screen no-touch"
    BASE_FLAGS="$BASE_FLAGS -skin 480x800"
    BASE_FLAGS="$BASE_FLAGS -delay-adb"
    BASE_FLAGS="$BASE_FLAGS -vsync-rate 15"
fi
BASE_FLAGS="$BASE_FLAGS $EXTRA_FLAGS"

# ============================================================
# Post-boot optimization function (called per emulator instance)
# ============================================================
optimize_instance() {
    local SERIAL="$1"
    local IDX="$2"
    local ADB="adb -s $SERIAL"

    $ADB shell settings put global window_animation_scale 0 2>/dev/null
    $ADB shell settings put global transition_animation_scale 0 2>/dev/null
    $ADB shell settings put global animator_duration_scale 0 2>/dev/null

    if [ "${DISABLE_HIDDEN_POLICY:-true}" = "true" ]; then
        $ADB shell "settings put global hidden_api_policy_pre_p_apps 1;settings put global hidden_api_policy_p_apps 1;settings put global hidden_api_policy 1" 2>/dev/null
    fi

    if [ "${HEADLESS:-true}" = "true" ]; then
        $ADB shell settings put global stay_on_while_plugged_in 3 2>/dev/null
        $ADB shell settings put system screen_off_timeout 2147483647 2>/dev/null
        $ADB shell settings put system screen_brightness 0 2>/dev/null
        $ADB shell settings put system accelerometer_rotation 0 2>/dev/null
        $ADB shell settings put global auto_sync 0 2>/dev/null
        $ADB shell settings put secure location_mode 0 2>/dev/null
        $ADB shell wm size 480x800 2>/dev/null
        $ADB shell wm density 160 2>/dev/null

        # Disable Google bloat
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
            $ADB shell pm disable-user "$pkg" 2>/dev/null
        done

        # Kill non-essential processes
        for pkg in com.google.android.settings.intelligence \
            com.google.android.cellbroadcastreceiver \
            com.google.android.devicelockcontroller \
            com.google.android.partnersetup com.google.android.rkpdapp \
            com.google.android.configupdater \
            com.google.android.healthconnect.controller \
            com.google.android.onetimeinitializer \
            com.google.android.ext.services \
            com.android.imsserviceentitlement com.android.printspooler \
            com.android.traceur com.android.emergency \
            com.android.providers.calendar com.android.managedprovisioning \
            com.android.emulator.multidisplay com.android.localtransport \
            com.android.dynsystem; do
            $ADB shell am force-stop "$pkg" 2>/dev/null
            $ADB shell pm disable-user "$pkg" 2>/dev/null
        done

        $ADB shell settings put global activity_manager_constants max_cached_processes=4 2>/dev/null
        $ADB shell am kill-all 2>/dev/null
        $ADB root 2>/dev/null; sleep 1
        $ADB shell "echo 3 > /proc/sys/vm/drop_caches" 2>/dev/null
        $ADB unroot 2>/dev/null
        $ADB shell cmd netpolicy set restrict-background true 2>/dev/null
        $ADB shell dumpsys deviceidle disable 2>/dev/null
        echo "[emu-${IDX}] Headless optimizations applied"
    fi
}

# ============================================================
# Boot watcher + post-boot features (per instance)
# ============================================================
wait_and_setup() {
    local SERIAL="$1"
    local IDX="$2"
    local CONSOLE_PORT="$3"
    local THIS_ADB_PORT="$4"
    local ADB="adb -s $SERIAL"

    emit_state "ANDROID_BOOTING" "$IDX"
    $ADB wait-for-device
    echo "[emu-${IDX}] Device $SERIAL connected, waiting for boot..."

    BOOT_TIMEOUT=300
    ELAPSED=0
    while [ $ELAPSED -lt $BOOT_TIMEOUT ]; do
        BOOT=$($ADB shell getprop sys.boot_completed 2>/dev/null | tr -d '\r')
        if [ "$BOOT" = "1" ]; then
            echo "[emu-${IDX}] Boot completed in ${ELAPSED}s"
            optimize_instance "$SERIAL" "$IDX"

            emit_state "ANDROID_READY" "$IDX"
            echo "[emu-${IDX}] Ready — ADB: adb connect <host>:${THIS_ADB_PORT}"

            # Pro features (only on first instance)
            if [ "$IDX" = "1" ]; then
                if [ "${ROOTED:-false}" = "true" ] && [ -f /opt/scripts/magisk-first-boot.sh ]; then
                    RAMDISK="$ANDROID_SDK_ROOT/system-images/android-${API_LEVEL}/${ABI%/*}/${ARCHITECTURE}/ramdisk.img"
                    echo "[emu-${IDX}] Running Magisk root setup..."
                    /opt/scripts/magisk-first-boot.sh "$RAMDISK"
                fi
                if [ -f /opt/scripts/anti-emu.sh ]; then
                    echo "[emu-${IDX}] Running anti-emu..."
                    /opt/scripts/anti-emu.sh
                fi
                if [ -f /opt/scripts/install-playstore.sh ]; then
                    echo "[emu-${IDX}] Installing Play Store..."
                    /opt/scripts/install-playstore.sh
                fi
                if [ "${SSLBYPASS:-false}" = "true" ] && [ -f /opt/scripts/ssl-bypass.sh ]; then
                    echo "[emu-${IDX}] Running SSL bypass..."
                    /opt/scripts/ssl-bypass.sh &
                fi
            fi
            return 0
        fi
        sleep 5
        ELAPSED=$((ELAPSED + 5))
    done
    emit_state "ANDROID_BOOT_TIMEOUT" "$IDX"
    echo "[emu-${IDX}] WARNING: Boot did not complete within ${BOOT_TIMEOUT}s"
    return 1
}

# ============================================================
# Launch emulators
# ============================================================
for IDX in $(seq 1 "$EMULATOR_COUNT"); do
    if [ "$EMULATOR_COUNT" -eq 1 ]; then
        AVD_NAME="android"
    else
        AVD_NAME="android-${IDX}"
    fi
    CONSOLE_PORT=$((5554 + (IDX - 1) * 2))
    THIS_ADB_PORT=$((CONSOLE_PORT + 1))
    SERIAL="emulator-${CONSOLE_PORT}"

    # Socat forwarding for this instance (delayed until port binds)
    if [ -n "$LOCAL_IP" ]; then
        (
            for j in $(seq 1 30); do
                ss -tln 2>/dev/null | grep -q ":${THIS_ADB_PORT} " && break
                sleep 1
            done
            socat tcp-listen:"$CONSOLE_PORT",bind="$LOCAL_IP",fork tcp:127.0.0.1:"$CONSOLE_PORT" &
            socat tcp-listen:"$THIS_ADB_PORT",bind="$LOCAL_IP",fork tcp:127.0.0.1:"$THIS_ADB_PORT" &
        ) &
    fi

    # Boot watcher in background
    wait_and_setup "$SERIAL" "$IDX" "$CONSOLE_PORT" "$THIS_ADB_PORT" &

    # Launch emulator
    EMU_FLAGS="-avd ${AVD_NAME} -port ${CONSOLE_PORT} ${BASE_FLAGS}"
    # Only append -qemu on last flag set (can't have multiple -qemu)
    EMU_FLAGS="$EMU_FLAGS -qemu -append panic=1"

    echo "[emu-${IDX}] Starting ${AVD_NAME} on port ${CONSOLE_PORT}/${THIS_ADB_PORT}..."

    if [ "$EMULATOR_COUNT" -eq 1 ]; then
        # Single instance — run in foreground with restart support
        while true; do
            emulator $EMU_FLAGS
            EXIT_CODE=$?
            if [ -f /tmp/.emu_restart ]; then
                rm -f /tmp/.emu_restart
                rm -f "$ANDROID_AVD_HOME/${AVD_NAME}.avd/"*.lock 2>/dev/null
                echo "[emu-1] Restarting emulator (Magisk cold boot)..."
                sleep 2
                continue
            fi
            emit_state "ANDROID_STOPPED" "1"
            echo "[emu-1] Emulator exited with code $EXIT_CODE"
            break
        done
    else
        # Multi-instance — run in background, stagger by 5s
        emulator $EMU_FLAGS &
        sleep 5
    fi
done

# For multi-instance: wait for all background emulator processes
if [ "$EMULATOR_COUNT" -gt 1 ]; then
    echo "[emu] All $EMULATOR_COUNT emulators launched. Waiting..."
    wait
    emit_state "ANDROID_STOPPED" "all"
    echo "[emu] All emulators exited"
fi

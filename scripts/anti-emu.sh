#!/bin/bash
# anti-emu.sh - Anti-emulator detection via Zygisk modules (no Frida needed)
#
# Default (STRONGERANTIEMU=false):
#   - device_faker: Spoof Build.* + system properties (Pixel 8 profile)
#   - Zygisk-Assistant: Hide root + Zygisk traces + sensitive props
#   - Randomize Android ID + serial
#   - Hide emulator filesystem artifacts
#
# Moderate (STRONGERANTIEMU=true):
#   - Everything above, plus:
#   - COPG: Spoof /proc/cpuinfo (hide QEMU CPU)
#   - TrickyStore: Fake attestation certs (no TEE on emulator)
#   - PlayIntegrityFork: Pass Play Integrity BASIC/DEVICE
#   - Frida server staged but NOT auto-started (manual use only)

ADB="adb -s emulator-5554"
ANTI_EMU_DIR="/opt/anti-emu"
MARKER="$ANTI_EMU_DIR/.applied"

wait_for_boot() {
    $ADB wait-for-device
    for i in $(seq 1 180); do
        BOOT=$($ADB shell getprop sys.boot_completed 2>/dev/null | tr -d '\r')
        [ "$BOOT" = "1" ] && return 0
        sleep 2
    done
    return 1
}

wait_for_su() {
    for i in $(seq 1 30); do
        $ADB shell "su 0 -c id" 2>/dev/null | grep -q "uid=0" && return 0
        sleep 3
    done
    return 1
}

install_module() {
    local NAME="$1"
    local ZIP="$2"
    if [ -f "$ZIP" ]; then
        $ADB push "$ZIP" /data/local/tmp/module.zip 2>/dev/null
        if $ADB shell "su 0 -c 'magisk --install-module /data/local/tmp/module.zip'" 2>/dev/null; then
            echo "[anti-emu] $NAME: installed"
            return 0
        else
            echo "[anti-emu] $NAME: install failed"
            return 1
        fi
    else
        echo "[anti-emu] $NAME: zip not found at $ZIP"
        return 1
    fi
}

# ============================================================
echo "[anti-emu] Starting anti-emulator setup..."

# Wait for Magisk setup to complete first (if ROOTED=yes)
if [ "${ROOTED:-no}" = "yes" ] || [ "${ROOTED:-no}" = "YES" ]; then
    echo "[anti-emu] Waiting for Magisk setup to complete..."
    for i in $(seq 1 120); do
        [ -f /tmp/.magisk_ready ] && break
        [ -f /opt/magisk/.setup_done ] && break
        sleep 5
    done
    if [ ! -f /tmp/.magisk_ready ] && [ ! -f /opt/magisk/.setup_done ]; then
        echo "[anti-emu] WARNING: Magisk setup signal not received after 10 min"
    fi
fi

echo "[anti-emu] Waiting for boot..."
wait_for_boot
sleep 5

# Skip if already applied
if [ -f "$MARKER" ]; then
    echo "[anti-emu] Already applied, skipping."
    exit 0
fi

# Check if we have root (Magisk or adb root)
HAS_MAGISK=false
HAS_ADB_ROOT=false

if $ADB shell "su 0 -c id" 2>/dev/null | grep -q "uid=0"; then
    HAS_MAGISK=true
    echo "[anti-emu] Magisk root available"
elif $ADB root 2>&1 | grep -q "restarting"; then
    HAS_ADB_ROOT=true
    sleep 2
    echo "[anti-emu] adb root available"
fi

if ! $HAS_MAGISK && ! $HAS_ADB_ROOT; then
    echo "[anti-emu] WARNING: No root access — limited anti-emu (properties only via setprop)"
    # Best-effort: change non-ro properties
    ANDROID_ID=$(cat /proc/sys/kernel/random/uuid | tr -d '-' | head -c 16)
    $ADB shell "settings put secure android_id $ANDROID_ID" 2>/dev/null
    touch "$MARKER"
    exit 0
fi

MODULES_INSTALLED=false

# ============================================================
# CORE: Device identity spoofing (Pixel 8 profile)
# ============================================================
echo "[anti-emu] === Device identity spoofing ==="

if $HAS_MAGISK; then
    # Ensure Zygisk is enabled
    $ADB shell "su 0 -c 'magisk --sqlite \"REPLACE INTO settings (key,value) VALUES(\\\"zygisk\\\",1)\"'" 2>/dev/null

    # Try device_faker (Zygisk module — only works if it has x86_64 .so)
    if [ -f "$ANTI_EMU_DIR/device_faker.zip" ]; then
        install_module "device_faker" "$ANTI_EMU_DIR/device_faker.zip" && MODULES_INSTALLED=true
        if [ -f "$ANTI_EMU_DIR/pixel8-profile.toml" ]; then
            $ADB shell "su 0 -c 'mkdir -p /data/adb/device_faker/config'" 2>/dev/null
            $ADB push "$ANTI_EMU_DIR/pixel8-profile.toml" /data/local/tmp/config.toml 2>/dev/null
            $ADB shell "su 0 -c 'cp /data/local/tmp/config.toml /data/adb/device_faker/config/config.toml'" 2>/dev/null
        fi
    fi

    # Always apply resetprop as fallback/complement (works on x86_64)
    # device_faker is ARM-only, so resetprop handles x86_64 emulators
    echo "[anti-emu] Applying resetprop Pixel 8 profile..."
    PROP_CMD="su 0 -c resetprop"
    $ADB shell "$PROP_CMD ro.product.model 'Pixel 8'" 2>/dev/null
    $ADB shell "$PROP_CMD ro.product.brand 'google'" 2>/dev/null
    $ADB shell "$PROP_CMD ro.product.name 'shiba'" 2>/dev/null
    $ADB shell "$PROP_CMD ro.product.device 'shiba'" 2>/dev/null
    $ADB shell "$PROP_CMD ro.product.manufacturer 'Google'" 2>/dev/null
    $ADB shell "$PROP_CMD ro.hardware 'shiba'" 2>/dev/null
    $ADB shell "$PROP_CMD ro.product.board 'shiba'" 2>/dev/null
    $ADB shell "$PROP_CMD ro.build.fingerprint 'google/shiba/shiba:14/AP4A.250405.002/12767828:user/release-keys'" 2>/dev/null
    $ADB shell "$PROP_CMD ro.bootloader 'slider-14.1-12385275'" 2>/dev/null
    $ADB shell "$PROP_CMD ro.baseband 'g5300q-241203-250108-B-12538801'" 2>/dev/null
    $ADB shell "$PROP_CMD --delete ro.kernel.qemu" 2>/dev/null
    $ADB shell "$PROP_CMD ro.build.type 'user'" 2>/dev/null
    $ADB shell "$PROP_CMD ro.build.tags 'release-keys'" 2>/dev/null
    $ADB shell "$PROP_CMD ro.build.display.id 'AP4A.250405.002'" 2>/dev/null
    $ADB shell "$PROP_CMD ro.product.system.model 'Pixel 8'" 2>/dev/null
    $ADB shell "$PROP_CMD ro.product.vendor.model 'Pixel 8'" 2>/dev/null
    $ADB shell "$PROP_CMD ro.product.vendor.brand 'google'" 2>/dev/null
    $ADB shell "$PROP_CMD ro.product.vendor.device 'shiba'" 2>/dev/null
    $ADB shell "$PROP_CMD ro.serialno '29261JEHN$(shuf -i 1000-9999 -n 1)'" 2>/dev/null
    # Disable ADB authentication for external connections
    $ADB shell "$PROP_CMD ro.adb.secure 0" 2>/dev/null
    echo "[anti-emu] resetprop applied (including ro.adb.secure=0)"
elif $HAS_ADB_ROOT; then
    # No Magisk/resetprop — edit build.prop directly (requires remount)
    echo "[anti-emu] Using adb root + build.prop edit..."
    $ADB remount 2>/dev/null
    $ADB shell "sed -i \
        -e 's/^ro.product.model=.*/ro.product.model=Pixel 8/' \
        -e 's/^ro.product.brand=.*/ro.product.brand=google/' \
        -e 's/^ro.product.device=.*/ro.product.device=shiba/' \
        -e 's/^ro.hardware=.*/ro.hardware=shiba/' \
        -e 's/^ro.build.type=.*/ro.build.type=user/' \
        -e 's/^ro.build.tags=.*/ro.build.tags=release-keys/' \
        -e '/^ro.kernel.qemu=/d' \
        /system/build.prop" 2>/dev/null && \
        echo "[anti-emu] build.prop patched (reboot needed for ro.* props)" || \
        echo "[anti-emu] build.prop patch failed (system may be read-only)"
    $ADB unroot 2>/dev/null
fi

# ============================================================
# CORE: Zygisk-Assistant (root + Zygisk hiding)
# ============================================================
echo "[anti-emu] === Installing Zygisk-Assistant ==="

if $HAS_MAGISK; then
    install_module "Zygisk-Assistant" "$ANTI_EMU_DIR/ZygiskAssistant.zip" && MODULES_INSTALLED=true
fi

# ============================================================
# CORE: Hide emulator artifacts + randomize IDs
# ============================================================
echo "[anti-emu] === Hiding emulator artifacts ==="

ANDROID_ID=$(cat /proc/sys/kernel/random/uuid | tr -d '-' | head -c 16)
$ADB shell "settings put secure android_id $ANDROID_ID" 2>/dev/null
echo "[anti-emu] Android ID randomized: $ANDROID_ID"

if $HAS_MAGISK; then
    # Hide emulator files via su
    $ADB shell "su 0 -c 'mv /system/bin/qemu-props /system/bin/.qemu-props 2>/dev/null'" 2>/dev/null
    $ADB shell "su 0 -c 'mv /system/lib64/libc_malloc_debug_qemu.so /system/lib64/.libc_malloc_debug_qemu.so 2>/dev/null'" 2>/dev/null
    # Delete qemu kernel prop
    $ADB shell "su 0 -c 'resetprop --delete ro.kernel.qemu'" 2>/dev/null
elif $HAS_ADB_ROOT; then
    $ADB shell "mv /system/bin/qemu-props /system/bin/.qemu-props 2>/dev/null" 2>/dev/null
    $ADB shell "mv /system/lib64/libc_malloc_debug_qemu.so /system/lib64/.libc_malloc_debug_qemu.so 2>/dev/null" 2>/dev/null
fi

# ============================================================
# MODERATE: Additional modules (STRONGERANTIEMU=true)
# ============================================================
if [ "${STRONGERANTIEMU,,}" = "true" ] && $HAS_MAGISK; then
    echo "[anti-emu] === Moderate anti-emu (STRONGERANTIEMU=true) ==="

    # COPG: CPU spoofing — ARM-only, skip on x86_64 emulators
    # (only install if x86_64 .so exists in the zip)
    if [ -f "$ANTI_EMU_DIR/COPG.zip" ] && unzip -l "$ANTI_EMU_DIR/COPG.zip" 2>/dev/null | grep -q "x86_64"; then
        echo "[anti-emu] Installing COPG (CPU spoof)..."
        install_module "COPG" "$ANTI_EMU_DIR/COPG.zip" && MODULES_INSTALLED=true
    else
        echo "[anti-emu] COPG: skipped (ARM-only, no x86_64 support)"
    fi

    # TrickyStore: Fake attestation certs for emulator (no TEE)
    echo "[anti-emu] Installing TrickyStore..."
    install_module "TrickyStore" "$ANTI_EMU_DIR/TrickyStore.zip" && MODULES_INSTALLED=true

    # PlayIntegrityFork: Pass Play Integrity
    echo "[anti-emu] Installing PlayIntegrityFork..."
    install_module "PlayIntegrityFork" "$ANTI_EMU_DIR/PlayIntegrityFork.zip" && MODULES_INSTALLED=true

    # Note: Frida is staged at /opt/anti-emu/frida-server but NOT auto-started
    # Start manually if needed: adb shell "su 0 -c '/opt/anti-emu/frida-server -D &'"
    echo "[anti-emu] Frida server staged (manual start only)"
fi

# ============================================================
# REBOOT if modules were installed
# ============================================================
if $MODULES_INSTALLED; then
    echo "[anti-emu] Rebooting to activate Zygisk modules..."
    $ADB reboot 2>/dev/null
    sleep 15
    wait_for_boot
    sleep 10

    # Verify modules loaded
    echo "[anti-emu] === Verification ==="
    if $HAS_MAGISK; then
        wait_for_su
        MODULES=$($ADB shell "su 0 -c 'ls /data/adb/modules/'" 2>/dev/null)
        echo "[anti-emu] Installed modules: $MODULES"
    fi

    # Verify device identity
    MODEL=$($ADB shell getprop ro.product.model 2>/dev/null | tr -d '\r')
    HW=$($ADB shell getprop ro.hardware 2>/dev/null | tr -d '\r')
    QEMU=$($ADB shell getprop ro.kernel.qemu 2>/dev/null | tr -d '\r')
    echo "[anti-emu] Model: $MODEL, Hardware: $HW, ro.kernel.qemu: '${QEMU:-deleted}'"

    if [ "$MODEL" = "Pixel 8" ] || echo "$MODULES" | grep -q "device_faker"; then
        echo "[anti-emu] Device spoofing: ACTIVE"
    else
        echo "[anti-emu] Device spoofing: may need another reboot"
    fi
fi

if $HAS_ADB_ROOT; then
    $ADB unroot 2>/dev/null
fi

touch "$MARKER"
echo "[anti-emu] Setup complete."

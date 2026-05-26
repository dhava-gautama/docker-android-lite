#!/bin/bash
# magisk-first-boot.sh - Fully automated Magisk root for Android emulators
# Uses rootAVD for patching + headless auto-grant via Magisk UI automation
# Controlled by ROOTED env var (default: yes). Zero user interaction, works headless.

RAMDISK_PATH="$1"
MARKER="/opt/magisk/.rooted"
SETUP_DONE="/opt/magisk/.setup_done"
ADB="adb -s emulator-5554"
ANDROID_HOME="${ANDROID_HOME:-/opt/android}"

# Validate ramdisk path
if [ -n "$RAMDISK_PATH" ] && [ ! -f "$RAMDISK_PATH" ]; then
    echo "[magisk] ERROR: ramdisk not found: $RAMDISK_PATH"
    exit 1
fi

wait_for_boot() {
    $ADB wait-for-device
    for i in $(seq 1 180); do
        BOOT=$($ADB shell getprop sys.boot_completed 2>/dev/null | tr -d '\r')
        [ "$BOOT" = "1" ] && return 0
        sleep 2
    done
    return 1
}

# Check ROOTED env var (accept "yes" or "true")
ROOTED_VAL="${ROOTED:-yes}"
ROOTED_VAL="${ROOTED_VAL,,}"  # lowercase
if [ "$ROOTED_VAL" != "yes" ] && [ "$ROOTED_VAL" != "true" ]; then
    echo "[magisk] ROOTED=${ROOTED}, skipping."
    exit 0
fi

# ============================================================
# Already fully set up - just ensure Magisk app exists
# ============================================================
if [ -f "$SETUP_DONE" ]; then
    echo "[magisk] Already set up, verifying..."
    wait_for_boot
    $ADB shell pm list packages 2>/dev/null | grep -q topjohnwu || \
        $ADB install -r /opt/magisk/rootAVD/Apps/Magisk.apk 2>/dev/null || true
    echo "[magisk] Ready."
    exit 0
fi

# ============================================================
# PHASE 1: Patch ramdisk with rootAVD (first boot, unrooted)
# ============================================================
if [ ! -f "$MARKER" ]; then
    echo "[magisk] === PHASE 1: Patching ramdisk with rootAVD ==="
    echo "[magisk] Waiting for unrooted boot..."
    wait_for_boot
    sleep 5

    RAMDISK_REL=$(echo "$RAMDISK_PATH" | sed "s|^$ANDROID_HOME/||")

    # Create auto-root rc script — runs as root via Magisk's overlay.d
    # Uses 'on property:sys.boot_completed=1' to ensure Magisk DB exists
    mkdir -p /opt/magisk/rootAVD/ADB/
    cat > /opt/magisk/rootAVD/ADB/auto-root.rc << 'RCEOF'
on property:sys.boot_completed=1
    exec u:r:magisk:s0 root root -- /system/bin/sh -c "while [ ! -S /dev/socket/magisk_log ]; do sleep 1; done; sleep 5; /data/adb/magisk/magisk --sqlite \"REPLACE INTO policies (uid,package_name,policy,until,logging,notification) VALUES(2000,'com.android.shell',2,0,1,1)\"; /data/adb/magisk/magisk --sqlite \"REPLACE INTO settings (key,value) VALUES('su_auto_response',1)\""
RCEOF

    echo "[magisk] Running rootAVD on: $RAMDISK_REL (with AddRCscripts)"
    (cd /opt/magisk/rootAVD && export ANDROID_HOME && bash rootAVD.sh "$RAMDISK_REL" AddRCscripts 2>&1)
    ROOTAVD_EXIT=$?
    if [ $ROOTAVD_EXIT -ne 0 ]; then
        echo "[magisk] ERROR: rootAVD failed with exit code $ROOTAVD_EXIT"
        exit 1
    fi

    touch "$MARKER"

    echo "[magisk] === Restarting emulator with patched ramdisk ==="
    # Signal start-emulator.sh to restart the emulator after it exits
    touch /tmp/.emu_restart
    $ADB emu kill 2>/dev/null || true
    sleep 3

    # Wait for emulator process to actually die
    echo "[magisk] Waiting for emulator process to exit..."
    for i in $(seq 1 30); do
        if ! pgrep -f "qemu-system" > /dev/null 2>&1; then
            echo "[magisk] Emulator process exited"
            break
        fi
        [ $i -eq 15 ] && pkill -f "qemu-system" 2>/dev/null
        sleep 1
    done
    sleep 5
    # Emulator will be restarted by start-emulator.sh's while loop
fi

# ============================================================
# PHASE 2: Wait for rooted boot + verify
# ============================================================
echo "[magisk] === PHASE 2: Waiting for rooted boot ==="
BOOT_OK=false
for i in $(seq 1 90); do
    if $ADB shell getprop sys.boot_completed 2>/dev/null | grep -q "1"; then
        echo "[magisk] Rooted boot complete!"
        BOOT_OK=true
        break
    fi
    [ $((i % 15)) -eq 0 ] && echo "[magisk] Waiting... ($i)"
    sleep 3
done
if ! $BOOT_OK; then
    echo "[magisk] WARNING: Boot did not complete within 270s"
fi

# Verify magiskd
if ! $ADB shell ps -A 2>/dev/null | grep -q magiskd; then
    echo "[magisk] ERROR: magiskd not running."
    exit 1
fi
echo "[magisk] magiskd RUNNING!"

# Install Magisk app
echo "[magisk] Installing Magisk app..."
$ADB install -r /opt/magisk/rootAVD/Apps/Magisk.apk 2>/dev/null || true
sleep 3

# --- CRITICAL: Write auto-root script before su grant attempts ---
# magiskd is running as root, which means /data/adb/ exists and is accessible.
# We push a script via ADB (writable as shell user) then use a trick:
# The Magisk CLI binary at /data/adb/magisk/magisk can be called directly
# by processes already running as root (like magiskd or init).
# We create a post-fs-data.d script so on NEXT reboot, root is auto-granted.
echo "[magisk] Writing auto-root post-fs-data.d script via magiskd..."
$ADB shell "
    # Create the script content in tmp (shell user can write here)
    cat > /data/local/tmp/setup-auto-root.sh << 'SEOF'
#!/system/bin/sh
mkdir -p /data/adb/post-fs-data.d
cat > /data/adb/post-fs-data.d/auto-root.sh << 'INNER'
#!/system/bin/sh
/data/adb/magisk/magisk --sqlite \"REPLACE INTO policies (uid,package_name,policy,until,logging,notification) VALUES(2000,'com.android.shell',2,0,1,1)\"
/data/adb/magisk/magisk --sqlite \"REPLACE INTO settings (key,value) VALUES('su_auto_response',1)\"
INNER
chmod 755 /data/adb/post-fs-data.d/auto-root.sh
/data/adb/post-fs-data.d/auto-root.sh
SEOF
    chmod 755 /data/local/tmp/setup-auto-root.sh
" 2>/dev/null

# Handle "Additional Setup" dialog (retry up to 3 times — dialog may appear late)
echo "[magisk] Checking for Additional Setup dialog..."
SETUP_HANDLED=false
for ATTEMPT in 1 2 3; do
    $ADB shell "am force-stop com.topjohnwu.magisk" 2>/dev/null
    sleep 1
    $ADB shell "am start -n com.topjohnwu.magisk/.ui.MainActivity" 2>/dev/null
    sleep 6
    $ADB shell "uiautomator dump /data/local/tmp/ui.xml" 2>/dev/null
    $ADB shell "cat /data/local/tmp/ui.xml" > /tmp/magisk_ui.xml 2>/dev/null

    if [ -f /tmp/magisk_ui.xml ] && grep -q 'Additional Setup\|Requires Additional' /tmp/magisk_ui.xml; then
        echo "[magisk] Found Additional Setup dialog (attempt $ATTEMPT), tapping OK..."
        OK_BOUNDS=$(grep -o 'text="OK"[^>]*bounds="[^"]*"' /tmp/magisk_ui.xml | grep -o 'bounds="[^"]*"' | head -1)
        if [ -n "$OK_BOUNDS" ]; then
            X1=$(echo "$OK_BOUNDS" | grep -o '\[[0-9]*' | head -1 | tr -d '[')
            Y1=$(echo "$OK_BOUNDS" | grep -o ',[0-9]*\]' | head -1 | tr -d ',]')
            X2=$(echo "$OK_BOUNDS" | grep -o '\[[0-9]*' | tail -1 | tr -d '[')
            Y2=$(echo "$OK_BOUNDS" | grep -o ',[0-9]*\]' | tail -1 | tr -d ',]')
            if [ -n "$X1" ] && [ -n "$Y1" ] && [ -n "$X2" ] && [ -n "$Y2" ]; then
                $ADB shell "input tap $(( (X1+X2)/2 )) $(( (Y1+Y2)/2 ))"
            fi
        fi
        echo "[magisk] Waiting for setup reboot..."
        sleep 30
        wait_for_boot
        sleep 15
        if ! $ADB shell ps -A 2>/dev/null | grep -q magiskd; then
            echo "[magisk] ERROR: magiskd not running after setup."
            exit 1
        fi
        SETUP_HANDLED=true
        break
    else
        echo "[magisk] Attempt $ATTEMPT: No Additional Setup dialog found"
        sleep 5
    fi
done
rm -f /tmp/magisk_ui.xml
$ADB shell "input keyevent KEYCODE_HOME" 2>/dev/null

# ============================================================
# PHASE 3: Auto-grant root to shell
# ============================================================
echo "[magisk] === PHASE 3: Auto-granting root ==="

SU_GRANTED=false

# --- Method 0: Write Magisk policy DB directly via Android's /data partition ---
# magiskd runs as root inside the emulator. The emulator's /data is stored on
# the AVD disk image. We can write to it via ADB by pushing a sqlite3 binary
# or by using Magisk's own --sqlite command via a creative su chain.
# Strategy: Create a post-fs-data.d script that auto-grants root on every boot,
# then reboot so it takes effect before any su call.
echo "[magisk] Trying Method 0: post-fs-data.d auto-root script..."
# Push the auto-root script via ADB (doesn't need root — /data/local/tmp is writable)
$ADB shell "cat > /data/local/tmp/install-auto-root.sh << 'AEOF'
#!/system/bin/sh
# This runs as root via magiskd's post-fs-data hook
mkdir -p /data/adb/post-fs-data.d
cat > /data/adb/post-fs-data.d/auto-root.sh << 'SEOF'
#!/system/bin/sh
# Auto-grant root to shell (uid 2000) and set auto-response to allow
/data/adb/magisk/magisk --sqlite \"REPLACE INTO policies (uid,package_name,policy,until,logging,notification) VALUES(2000,'com.android.shell',2,0,1,1)\"
/data/adb/magisk/magisk --sqlite \"REPLACE INTO settings (key,value) VALUES('su_auto_response',1)\"
SEOF
chmod 755 /data/adb/post-fs-data.d/auto-root.sh
# Also run it now
/data/adb/magisk/magisk --sqlite \"REPLACE INTO policies (uid,package_name,policy,until,logging,notification) VALUES(2000,'com.android.shell',2,0,1,1)\"
/data/adb/magisk/magisk --sqlite \"REPLACE INTO settings (key,value) VALUES('su_auto_response',1)\"
AEOF
chmod 755 /data/local/tmp/install-auto-root.sh" 2>/dev/null

# Trigger su request — this creates the deny entry in Magisk DB, but also
# shows the approval dialog. We don't care about the result here.
timeout 3 $ADB shell "su 0 -c '/data/local/tmp/install-auto-root.sh'" 2>/dev/null || true
sleep 2

# Check if su already works (unlikely on first attempt — Magisk denied it)
SU_TEST=$($ADB shell "su 0 -c id" 2>&1)
if echo "$SU_TEST" | grep -q "uid=0"; then
    echo "[magisk] ROOT VERIFIED (Method 0): $SU_TEST"
    SU_GRANTED=true
fi

# --- Method 1: adb root (works on userdebug/eng builds, NOT playstore) ---
if ! $SU_GRANTED; then
    echo "[magisk] Trying Method 1: adb root..."
    if $ADB root 2>&1 | grep -q "restarting"; then
        sleep 3
        $ADB shell "mkdir -p /data/adb/post-fs-data.d"
        $ADB shell "cat > /data/adb/post-fs-data.d/auto-root.sh << 'SCRIPT'
#!/system/bin/sh
magisk --sqlite \"REPLACE INTO policies (uid,package_name,policy,until,logging,notification) VALUES(2000,'com.android.shell',2,0,1,1)\"
magisk --sqlite \"REPLACE INTO settings (key,value) VALUES('su_auto_response',1)\"
SCRIPT"
        $ADB shell "chmod 755 /data/adb/post-fs-data.d/auto-root.sh"
        $ADB shell "magisk --sqlite \"REPLACE INTO policies (uid,package_name,policy,until,logging,notification) VALUES(2000,'com.android.shell',2,0,1,1)\""
        $ADB unroot 2>/dev/null
        sleep 3
        SU_TEST=$($ADB shell "su 0 -c id" 2>&1)
        if echo "$SU_TEST" | grep -q "uid=0"; then
            echo "[magisk] ROOT VERIFIED (adb root): $SU_TEST"
            SU_GRANTED=true
        fi
    else
        echo "[magisk] adb root not available (production build)"
    fi
fi

# --- Method 2: UI automation - toggle Shell su policy in Magisk Superuser tab ---
# When su is first called, Magisk creates a policy entry for com.android.shell
# with checked=false (denied). We navigate to the Superuser tab and toggle it on.
if ! $SU_GRANTED; then
    echo "[magisk] Trying Method 2: Superuser tab UI toggle..."

    # First, trigger a su request to ensure the Shell policy entry exists
    # (su will be denied, but Magisk will create the policy entry)
    $ADB shell "su 0 -c id" 2>/dev/null || true
    sleep 2

    # Open Magisk app
    $ADB shell "am start -n com.topjohnwu.magisk/.ui.MainActivity" 2>/dev/null
    sleep 3

    # Navigate to Superuser tab dynamically via uiautomator
    $ADB shell "uiautomator dump /data/local/tmp/nav.xml" 2>/dev/null
    $ADB shell "cat /data/local/tmp/nav.xml" > /tmp/nav.xml 2>/dev/null
    SU_TAB_BOUNDS=$(grep -o 'content-desc="Superuser"[^>]*bounds="[^"]*"' /tmp/nav.xml 2>/dev/null | grep -o 'bounds="[^"]*"' | head -1)
    rm -f /tmp/nav.xml
    if [ -n "$SU_TAB_BOUNDS" ]; then
        TX1=$(echo "$SU_TAB_BOUNDS" | grep -o '\[[0-9]*' | head -1 | tr -d '[')
        TY1=$(echo "$SU_TAB_BOUNDS" | grep -o ',[0-9]*\]' | head -1 | tr -d ',]')
        TX2=$(echo "$SU_TAB_BOUNDS" | grep -o '\[[0-9]*' | tail -1 | tr -d '[')
        TY2=$(echo "$SU_TAB_BOUNDS" | grep -o ',[0-9]*\]' | tail -1 | tr -d ',]')
        if [ -n "$TX1" ] && [ -n "$TY1" ] && [ -n "$TX2" ] && [ -n "$TY2" ]; then
            $ADB shell "input tap $(( (TX1+TX2)/2 )) $(( (TY1+TY2)/2 ))"
            echo "[magisk] Tapped Superuser tab at $(( (TX1+TX2)/2 )),$(( (TY1+TY2)/2 ))"
        else
            echo "[magisk] Superuser tab bounds parse failed, using fallback"
            $ADB shell "input tap 405 2290"
        fi
    else
        echo "[magisk] Superuser tab not found in UI, using fallback coordinates"
        $ADB shell "input tap 405 2290"
    fi
    sleep 2

    # Dump UI to emulator, pull to host, then grep locally (avoids shell escaping issues)
    $ADB shell "uiautomator dump /data/local/tmp/su_tab.xml" 2>/dev/null
    $ADB shell "cat /data/local/tmp/su_tab.xml" > /tmp/su_tab.xml 2>/dev/null

    if [ -f /tmp/su_tab.xml ]; then
        # Find the policy_indicator switch bounds using local grep (no escaping issues)
        SWITCH_BOUNDS=$(grep -o 'policy_indicator[^>]*bounds="[^"]*"' /tmp/su_tab.xml | grep -o 'bounds="[^"]*"' | head -1)
        echo "[magisk] Switch search result: $SWITCH_BOUNDS"

        if [ -n "$SWITCH_BOUNDS" ]; then
            SW_X1=$(echo "$SWITCH_BOUNDS" | grep -o '\[[0-9]*' | head -1 | tr -d '[')
            SW_Y1=$(echo "$SWITCH_BOUNDS" | grep -o ',[0-9]*\]' | head -1 | tr -d ',]')
            SW_X2=$(echo "$SWITCH_BOUNDS" | grep -o '\[[0-9]*' | tail -1 | tr -d '[')
            SW_Y2=$(echo "$SWITCH_BOUNDS" | grep -o ',[0-9]*\]' | tail -1 | tr -d ',]')
            if [ -n "$SW_X1" ] && [ -n "$SW_Y1" ] && [ -n "$SW_X2" ] && [ -n "$SW_Y2" ]; then
                TAP_X=$(( (SW_X1+SW_X2)/2 ))
                TAP_Y=$(( (SW_Y1+SW_Y2)/2 ))
                $ADB shell "input tap $TAP_X $TAP_Y"
                echo "[magisk] Toggled Shell su policy switch at $TAP_X,$TAP_Y"
            else
                echo "[magisk] Switch bounds parse failed"
            fi
        else
            echo "[magisk] Shell policy switch not found in Superuser tab"
            echo "[magisk] UI content: $(grep -o 'text="[^"]*"' /tmp/su_tab.xml | head -10)"
        fi
        rm -f /tmp/su_tab.xml
    else
        echo "[magisk] Failed to pull UI dump"
    fi
    sleep 2

    # Go home to dismiss Magisk app
    $ADB shell "input keyevent KEYCODE_HOME" 2>/dev/null
    sleep 1

    SU_TEST=$($ADB shell "su 0 -c id" 2>&1)
    if echo "$SU_TEST" | grep -q "uid=0"; then
        echo "[magisk] ROOT VERIFIED (UI toggle): $SU_TEST"
        SU_GRANTED=true
    fi
fi

# --- Method 3: Reboot to trigger post-fs-data.d auto-root script ---
# The auto-root script was written above. Reboot so magiskd runs it as root.
if ! $SU_GRANTED; then
    echo "[magisk] Trying Method 3: reboot for post-fs-data.d auto-root..."
    # First, try to run setup-auto-root.sh via su (will be denied but may create the policy entry)
    timeout 5 $ADB shell "su 0 -c '/data/local/tmp/setup-auto-root.sh'" 2>/dev/null || true
    sleep 2

    # Reboot via restart mechanism
    echo "[magisk] Rebooting for auto-root script execution..."
    touch /tmp/.emu_restart
    $ADB emu kill 2>/dev/null || true
    sleep 10
    wait_for_boot
    sleep 10

    # Verify magiskd still running
    if ! $ADB shell ps -A 2>/dev/null | grep -q magiskd; then
        echo "[magisk] ERROR: magiskd not running after reboot"
    fi

    SU_TEST=$($ADB shell "su 0 -c id" 2>&1)
    if echo "$SU_TEST" | grep -q "uid=0"; then
        echo "[magisk] ROOT VERIFIED (Method 3 - post-fs-data.d): $SU_TEST"
        SU_GRANTED=true
    fi
fi

if ! $SU_GRANTED; then
    echo "[magisk] WARNING: All auto-grant methods failed. su requires manual approval."
    echo "[magisk] The emulator is rooted (magiskd running) but shell su not yet granted."
fi

# ============================================================
# PHASE 4: Final verification
# ============================================================
echo "[magisk] === PHASE 4: Final Status ==="

$ADB shell pm list packages 2>/dev/null | grep -q vending && echo "[magisk] PLAY STORE: confirmed"
MAGISK_VER=$($ADB shell "magisk -v" 2>/dev/null || $ADB shell "su 0 -c 'magisk -v'" 2>/dev/null)
[ -n "$MAGISK_VER" ] && echo "[magisk] MAGISK: $MAGISK_VER"

touch "$SETUP_DONE"

# Signal that Magisk setup is complete — anti-emu and ssl-bypass wait for this
touch /tmp/.magisk_ready

echo "[magisk] ============================================"
echo "[magisk] Setup complete! Rooted emulator ready."
echo "[magisk] ============================================"

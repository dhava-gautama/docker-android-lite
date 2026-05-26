#!/bin/bash
# ssl-bypass.sh - Stealth SSL interception with in-container mitmproxy
# Layer 1: AlwaysTrustUserCerts (user CA → system cert store)
# Layer 2: ZygiskSSLUnpinning (if x86_64 supported)
# Layer 3: iptables transparent redirect → mitmproxy
# mitmweb UI on port 8081, no password required
#
# Controlled by SSLBYPASS=true/false

ADB="adb -s emulator-5554"
SSL_DIR="/opt/ssl-bypass"
MARKER="$SSL_DIR/.installed"
MITM_HOME="$SSL_DIR/.mitmproxy"
TRAFFIC_DIR="$SSL_DIR/traffic"

wait_for_boot() {
    $ADB wait-for-device
    for i in $(seq 1 180); do
        BOOT=$($ADB shell getprop sys.boot_completed 2>/dev/null | tr -d '\r')
        [ "$BOOT" = "1" ] && return 0
        sleep 2
    done
    return 1
}

start_mitmweb() {
    mkdir -p "$MITM_HOME" "$TRAFFIC_DIR"
    if ! command -v mitmweb > /dev/null 2>&1; then
        echo "[ssl] mitmweb not installed"
        return 1
    fi

    # Generate argon2 hash for password "mitmweb"
    WEB_PASS_HASH=$(/opt/mitmproxy-venv/bin/python3 -c "
from argon2 import PasswordHasher
print(PasswordHasher().hash('mitmweb'))
" 2>/dev/null)

    # WireGuard mode: emulator connects via WireGuard VPN
    # - No proxy settings visible to apps (stealthier than HTTP proxy)
    # - Captures ALL traffic (TCP + UDP), not just HTTP
    # - WireGuard config generated at $MITM_HOME/wireguard-client.conf
    # - Install WireGuard app on emulator, import config via ADB
    echo "[ssl] Starting mitmweb in WireGuard mode..."
    echo "[ssl]   Web UI: http://<host>:8081 (password: mitmweb)"
    echo "[ssl]   WireGuard port: 51820/udp (internal)"
    echo "[ssl]   Config: $MITM_HOME/wireguard-client.conf"

    # Run in FOREGROUND
    exec mitmweb \
        --mode wireguard \
        --web-host 0.0.0.0 --web-port 8081 \
        --set confdir="$MITM_HOME" \
        --set block_global=false \
        --set ssl_insecure=true \
        --set "web_password=$WEB_PASS_HASH" \
        --no-web-open-browser \
        -w "$TRAFFIC_DIR/traffic_$(date +%Y%m%d_%H%M%S).flow"
}

# Check SSLBYPASS env var
if [ "${SSLBYPASS,,}" != "true" ]; then
    echo "[ssl] SSLBYPASS=${SSLBYPASS:-false}, skipping."
    exit 0
fi

# If already installed, just start mitmweb (foreground, keeps running)
if [ -f "$MARKER" ]; then
    echo "[ssl] Modules already installed."
    wait_for_boot
    sleep 5

    start_mitmweb  # blocks forever (exec)
    exit 0
fi

echo "[ssl] ============================================"
echo "[ssl] Setting up stealth SSL interception"
echo "[ssl] ============================================"

# Wait for Magisk + anti-emu to complete
echo "[ssl] Waiting for Magisk setup..."
for i in $(seq 1 120); do
    [ -f /tmp/.magisk_ready ] && break
    [ -f /opt/magisk/.setup_done ] && break
    sleep 5
done

echo "[ssl] Waiting for anti-emu..."
for i in $(seq 1 60); do
    [ -f /opt/anti-emu/.applied ] && break
    sleep 5
done

echo "[ssl] Waiting for boot..."
wait_for_boot
sleep 5

# Wait for su
echo "[ssl] Waiting for su..."
for i in $(seq 1 30); do
    $ADB shell "su 0 -c id" 2>/dev/null | grep -q "uid=0" && break
    sleep 3
done
if ! $ADB shell "su 0 -c id" 2>/dev/null | grep -q "uid=0"; then
    echo "[ssl] ERROR: su not available"
    start_mitmweb  # start anyway for manual use
    exit 0
fi
echo "[ssl] su access confirmed"

# Generate mitmproxy CA cert by doing a quick start/stop
echo "[ssl] Generating mitmproxy CA cert..."
mkdir -p "$MITM_HOME" "$TRAFFIC_DIR"
if command -v mitmdump > /dev/null 2>&1; then
    timeout 5 mitmdump --set confdir="$MITM_HOME" -p 18888 2>/dev/null || true
    sleep 2
fi

# ============================================================
# Layer 1: AlwaysTrustUserCerts + CA cert
# ============================================================
echo "[ssl] === Layer 1: AlwaysTrustUserCerts ==="

if [ -f "$SSL_DIR/AlwaysTrustUserCerts.zip" ]; then
    $ADB push "$SSL_DIR/AlwaysTrustUserCerts.zip" /data/local/tmp/ 2>/dev/null
    $ADB shell "su 0 -c 'magisk --install-module /data/local/tmp/AlwaysTrustUserCerts.zip'" 2>/dev/null && \
        echo "[ssl] AlwaysTrustUserCerts: installed" || \
        echo "[ssl] AlwaysTrustUserCerts: install failed"
fi

if [ -f "$MITM_HOME/mitmproxy-ca-cert.pem" ]; then
    echo "[ssl] Installing mitmproxy CA cert..."
    HASH=$(openssl x509 -inform PEM -subject_hash_old -in "$MITM_HOME/mitmproxy-ca-cert.pem" 2>/dev/null | head -1)
    if [ -n "$HASH" ]; then
        cp "$MITM_HOME/mitmproxy-ca-cert.pem" "/tmp/${HASH}.0"
        $ADB push "/tmp/${HASH}.0" /data/local/tmp/ 2>/dev/null
        $ADB shell "su 0 -c 'mkdir -p /data/misc/user/0/cacerts-added && cp /data/local/tmp/${HASH}.0 /data/misc/user/0/cacerts-added/ && chmod 644 /data/misc/user/0/cacerts-added/${HASH}.0'" 2>/dev/null && \
            echo "[ssl] CA cert installed (${HASH}.0)" || \
            echo "[ssl] CA cert install failed"
        rm -f "/tmp/${HASH}.0"
    fi
else
    echo "[ssl] CA cert not generated yet"
fi

# ============================================================
# Layer 2: ZygiskSSLUnpinning (skip if ARM-only)
# ============================================================
echo "[ssl] === Layer 2: SSL Unpinning ==="
$ADB shell "su 0 -c 'magisk --sqlite \"REPLACE INTO settings (key,value) VALUES(\\\"zygisk\\\",1)\"'" 2>/dev/null

if [ -f "$SSL_DIR/ZygiskSSLUnpinning.zip" ] && unzip -l "$SSL_DIR/ZygiskSSLUnpinning.zip" 2>/dev/null | grep -q "x86_64"; then
    $ADB push "$SSL_DIR/ZygiskSSLUnpinning.zip" /data/local/tmp/ 2>/dev/null
    $ADB shell "su 0 -c 'magisk --install-module /data/local/tmp/ZygiskSSLUnpinning.zip'" 2>/dev/null && \
        echo "[ssl] ZygiskSSLUnpinning: installed" || \
        echo "[ssl] ZygiskSSLUnpinning: install failed"
else
    echo "[ssl] ZygiskSSLUnpinning: skipped (ARM-only)"
fi

# Reboot to activate modules
echo "[ssl] Rebooting to activate modules..."
$ADB reboot 2>/dev/null
sleep 15
wait_for_boot
sleep 10

# Wait for su after reboot
for i in $(seq 1 20); do
    $ADB shell "su 0 -c id" 2>/dev/null | grep -q "uid=0" && break
    sleep 3
done

# Re-apply ro.adb.secure=0 (resetprop doesn't survive reboots)
$ADB shell "su 0 -c 'resetprop ro.adb.secure 0'" 2>/dev/null

# ============================================================
# Layer 3: WireGuard VPN tunnel (replaces HTTP proxy + iptables)
# ============================================================
# WireGuard mode: ALL traffic goes through VPN tunnel to mitmproxy
# - No proxy settings visible to apps (stealthier)
# - Captures TCP + UDP (not just HTTP)
# - mitmweb generates WireGuard config, we install WireGuard app + import config
echo "[ssl] === Layer 3: WireGuard VPN tunnel ==="

# Install WireGuard app from Play Store or F-Droid
echo "[ssl] Installing WireGuard app..."
$ADB shell "su 0 -c 'pm install-existing com.wireguard.android'" 2>/dev/null || \
    $ADB shell "am start -a android.intent.action.VIEW -d 'market://details?id=com.wireguard.android'" 2>/dev/null || true

# The WireGuard client config will be generated when mitmweb starts
# and placed at $MITM_HOME/wireguard-client.conf
# We'll push it to the emulator after mitmweb starts

# ============================================================
# Mark as installed + start mitmweb (foreground, keeps running)
# ============================================================
touch "$MARKER"

echo "[ssl] === Verification ==="
$ADB shell "su 0 -c 'ls /data/adb/modules/'" 2>/dev/null | grep -qi trust && echo "[ssl] AlwaysTrustUserCerts: ACTIVE"

echo "[ssl] ============================================"
echo "[ssl] SSL interception ready!"
echo "[ssl] mitmweb password: mitmweb"
echo "[ssl] WireGuard config will be at: $MITM_HOME/wireguard-client.conf"
echo "[ssl] Import it into WireGuard app on emulator after mitmweb starts"
echo "[ssl] Starting mitmweb in WireGuard mode..."
echo "[ssl] ============================================"

start_mitmweb  # exec — replaces shell, keeps supervisord happy

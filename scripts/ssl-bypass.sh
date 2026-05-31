#!/bin/bash
# ssl-bypass.sh - 4-layer stealth SSL interception
#
# Layer 1: AlwaysTrustUserCerts (user CA → system cert store via Magisk)
# Layer 2: iptables transparent redirect (kernel-level, invisible to apps)
# Layer 3: ZygiskFrida + httptoolkit unpinning scripts (stealthiest Frida)
# Layer 4: mitmweb UI on port 8081
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

    WEB_PASS_HASH=$(/opt/mitmproxy-venv/bin/python3 -c "
from argon2 import PasswordHasher
print(PasswordHasher().hash('mitmweb'))
" 2>/dev/null)

    echo "[ssl] Starting mitmweb in transparent mode..."
    echo "[ssl]   Web UI: http://<host>:8081 (password: mitmweb)"

    exec mitmweb \
        --mode transparent \
        --web-host 0.0.0.0 --web-port 8081 \
        --listen-port 8080 \
        --set confdir="$MITM_HOME" \
        --set block_global=false \
        --set ssl_insecure=true \
        --set "web_password=$WEB_PASS_HASH" \
        --no-web-open-browser \
        -w "$TRAFFIC_DIR/traffic_$(date +%Y%m%d_%H%M%S).flow"
}

setup_iptables() {
    # Redirect all outgoing HTTPS/HTTP from emulator through mitmproxy
    # 10.0.2.2 = emulator's gateway (host machine)
    # Using a dedicated chain to avoid conflicts
    echo "[ssl] Setting up iptables transparent redirect..."
    $ADB shell "su 0 -c '
        iptables -t nat -N MITMPROXY 2>/dev/null
        iptables -t nat -F MITMPROXY
        iptables -t nat -A MITMPROXY -o lo -j RETURN
        iptables -t nat -A MITMPROXY -d 10.0.2.0/24 -j RETURN
        iptables -t nat -A MITMPROXY -p tcp --dport 443 -j DNAT --to-destination 10.0.2.2:8080
        iptables -t nat -A MITMPROXY -p tcp --dport 80 -j DNAT --to-destination 10.0.2.2:8080
        iptables -t nat -A OUTPUT -j MITMPROXY
    '" 2>/dev/null && echo "[ssl] iptables redirect: ACTIVE" || echo "[ssl] iptables redirect: FAILED"

    # Make persistent across reboots via post-fs-data.d script
    $ADB shell "su 0 -c 'mkdir -p /data/adb/service.d && cat > /data/adb/service.d/ssl-redirect.sh << \"SEOF\"
#!/system/bin/sh
sleep 30
iptables -t nat -N MITMPROXY 2>/dev/null
iptables -t nat -F MITMPROXY
iptables -t nat -A MITMPROXY -o lo -j RETURN
iptables -t nat -A MITMPROXY -d 10.0.2.0/24 -j RETURN
iptables -t nat -A MITMPROXY -p tcp --dport 443 -j DNAT --to-destination 10.0.2.2:8080
iptables -t nat -A MITMPROXY -p tcp --dport 80 -j DNAT --to-destination 10.0.2.2:8080
iptables -t nat -A OUTPUT -j MITMPROXY
SEOF
chmod 755 /data/adb/service.d/ssl-redirect.sh'" 2>/dev/null
}

# ============================================================
# Check SSLBYPASS env var
# ============================================================
if [ "${SSLBYPASS,,}" != "true" ]; then
    echo "[ssl] SSLBYPASS=${SSLBYPASS:-false}, skipping."
    exit 0
fi

# Already installed — just set up iptables + start mitmweb
if [ -f "$MARKER" ]; then
    echo "[ssl] Modules already installed."
    wait_for_boot
    sleep 5
    # Re-apply iptables (lost on reboot if service.d didn't run yet)
    for i in $(seq 1 20); do
        $ADB shell "su 0 -c id" 2>/dev/null | grep -q "uid=0" && break
        sleep 3
    done
    setup_iptables
    start_mitmweb
    exit 0
fi

echo "[ssl] ============================================"
echo "[ssl] Setting up 4-layer stealth SSL interception"
echo "[ssl] ============================================"

# Wait for Magisk + anti-emu
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
HAS_SU=false
for i in $(seq 1 30); do
    $ADB shell "su 0 -c id" 2>/dev/null | grep -q "uid=0" && { HAS_SU=true; break; }
    sleep 3
done
if ! $HAS_SU; then
    echo "[ssl] WARNING: su not available — limited SSL bypass (mitmweb only)"
    start_mitmweb
    exit 0
fi
echo "[ssl] su access confirmed"

# Generate mitmproxy CA cert
echo "[ssl] Generating mitmproxy CA cert..."
mkdir -p "$MITM_HOME" "$TRAFFIC_DIR"
if command -v mitmdump > /dev/null 2>&1; then
    timeout 5 mitmdump --set confdir="$MITM_HOME" -p 18888 2>/dev/null || true
    sleep 2
fi

# ============================================================
# Layer 1: AlwaysTrustUserCerts + CA cert
# ============================================================
echo "[ssl] === Layer 1: System CA trust ==="

$ADB shell "su 0 -c 'magisk --sqlite \"REPLACE INTO settings (key,value) VALUES(\\\"zygisk\\\",1)\"'" 2>/dev/null

if [ -f "$SSL_DIR/AlwaysTrustUserCerts.zip" ]; then
    $ADB push "$SSL_DIR/AlwaysTrustUserCerts.zip" /data/local/tmp/ 2>/dev/null
    $ADB shell "su 0 -c 'magisk --install-module /data/local/tmp/AlwaysTrustUserCerts.zip'" 2>/dev/null && \
        echo "[ssl] AlwaysTrustUserCerts: installed" || \
        echo "[ssl] AlwaysTrustUserCerts: install failed"
fi

if [ -f "$MITM_HOME/mitmproxy-ca-cert.pem" ]; then
    HASH=$(openssl x509 -inform PEM -subject_hash_old -in "$MITM_HOME/mitmproxy-ca-cert.pem" 2>/dev/null | head -1)
    if [ -n "$HASH" ]; then
        cp "$MITM_HOME/mitmproxy-ca-cert.pem" "/tmp/${HASH}.0"
        $ADB push "/tmp/${HASH}.0" /data/local/tmp/ 2>/dev/null
        $ADB shell "su 0 -c 'mkdir -p /data/misc/user/0/cacerts-added && cp /data/local/tmp/${HASH}.0 /data/misc/user/0/cacerts-added/ && chmod 644 /data/misc/user/0/cacerts-added/${HASH}.0'" 2>/dev/null && \
            echo "[ssl] CA cert installed (${HASH}.0)" || \
            echo "[ssl] CA cert install failed"
        rm -f "/tmp/${HASH}.0"
    fi
fi

# ============================================================
# Layer 2: iptables transparent redirect (kernel-level)
# ============================================================
echo "[ssl] === Layer 2: iptables transparent redirect ==="
# Will be applied after reboot (service.d script)

# ============================================================
# Layer 3: ZygiskFrida + unpinning scripts (stealthiest)
# ============================================================
echo "[ssl] === Layer 3: ZygiskFrida + SSL unpinning ==="

if [ -f "$SSL_DIR/ZygiskFrida.zip" ]; then
    $ADB push "$SSL_DIR/ZygiskFrida.zip" /data/local/tmp/ 2>/dev/null
    $ADB shell "su 0 -c 'magisk --install-module /data/local/tmp/ZygiskFrida.zip'" 2>/dev/null && \
        echo "[ssl] ZygiskFrida: installed (stealthiest Frida delivery)" || \
        echo "[ssl] ZygiskFrida: install failed"
fi

# Stage httptoolkit unpinning script for ZygiskFrida
if [ -d "$SSL_DIR/frida-unpinning" ]; then
    $ADB push "$SSL_DIR/frida-unpinning/frida-script.js" /data/local/tmp/ssl-unpin.js 2>/dev/null
    $ADB shell "su 0 -c 'mkdir -p /data/local/tmp/zygisk-frida && cp /data/local/tmp/ssl-unpin.js /data/local/tmp/zygisk-frida/config.js'" 2>/dev/null
    echo "[ssl] httptoolkit unpinning script: staged for ZygiskFrida"
fi

# Reboot to activate all modules
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

# Re-apply ro.adb.secure=0
$ADB shell "su 0 -c 'resetprop ro.adb.secure 0'" 2>/dev/null

# Apply iptables redirect
setup_iptables

# ============================================================
# Done — start mitmweb
# ============================================================
touch "$MARKER"

echo "[ssl] === Verification ==="
$ADB shell "su 0 -c 'ls /data/adb/modules/'" 2>/dev/null
$ADB shell "su 0 -c 'iptables -t nat -L MITMPROXY -n'" 2>/dev/null | head -5

echo "[ssl] ============================================"
echo "[ssl] 4-layer SSL interception ready!"
echo "[ssl]   Layer 1: AlwaysTrustUserCerts (system CA)"
echo "[ssl]   Layer 2: iptables transparent redirect (kernel)"
echo "[ssl]   Layer 3: ZygiskFrida + unpinning scripts"
echo "[ssl]   Layer 4: mitmweb on :8081 (password: mitmweb)"
echo "[ssl] ============================================"

start_mitmweb

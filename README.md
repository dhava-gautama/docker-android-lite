# docker-android-lite

Lightweight Android emulator in Docker. **~2.5 GB** compressed — no bloat, just the emulator.

## Quick Start

```bash
# Pull and run
docker run -d --name android \
  --device /dev/kvm \
  -p 5555:5555 \
  -v android-data:/data \
  ghcr.io/dhava-gautama/docker-android-lite:api-34

# Connect
adb connect localhost:5555
```

## Image Tags

| Tag | System Image | `adb root` | Play Store | Size |
|-----|-------------|------------|------------|------|
| `api-34` | google_apis | Yes | Aurora Store | ~2.5 GB |
| `api-34-lite` | AOSP (default) | Yes | None | ~2.0 GB |
| `api-34-gplaystore` | google_apis_playstore | No | Native | ~2.5 GB |
| `api-34-cuda` | google_apis | Yes | Aurora Store | ~3.5 GB |
| `api-34-gplaystore-cuda` | google_apis_playstore | No | Native | ~3.5 GB |
| `api-34-minimal` | — | — | — | ~500 MB |
| `api-33` | google_apis | Yes | Aurora Store | ~2.5 GB |
| `api-30` | google_apis | Yes | Aurora Store | ~2.5 GB |
| `api-30-lite` | AOSP | Yes | None | ~2.0 GB |

## Environment Variables

| Variable | Default | Description |
|----------|---------|-------------|
| `MEMORY` | `4096` | Emulator RAM in MB |
| `CORES` | `2` | CPU cores |
| `DEVICE_ID` | `pixel` | AVD device profile (`pixel`, `pixel_8`, etc.) |
| `HEADLESS` | `true` | No display, no audio — optimized for servers |
| `GPU_ACCELERATED` | `false` | Use host NVIDIA GPU (requires `-cuda` tag) |
| `ROOTED` | `false` | Magisk root via rootAVD (automated, zero interaction) |
| `STRONGERANTIEMU` | `false` | Anti-emulator detection bypass |
| `SSLBYPASS` | `false` | SSL interception via mitmweb (port 8081) |
| `DISABLE_HIDDEN_POLICY` | `true` | Allow access to hidden/private Android APIs |
| `EXTRA_FLAGS` | — | Additional emulator flags passed directly |

## Usage Examples

### Headless CI/CD

```bash
docker run -d --name android \
  --device /dev/kvm \
  -p 5555:5555 \
  -e MEMORY=4096 -e CORES=2 \
  -v android-data:/data \
  --restart unless-stopped \
  ghcr.io/dhava-gautama/docker-android-lite:api-34

adb connect localhost:5555
adb shell pm list packages
```

### Security Testing (root + anti-emu + SSL intercept)

```bash
docker run -d --name pentest \
  --device /dev/kvm \
  -p 5555:5555 -p 8081:8081 \
  -e MEMORY=8192 -e CORES=4 \
  -e ROOTED=true \
  -e STRONGERANTIEMU=true \
  -e SSLBYPASS=true \
  -v pentest-data:/data \
  ghcr.io/dhava-gautama/docker-android-lite:api-34

# ADB:     adb connect localhost:5555
# Screen:  scrcpy -s localhost:5555
# mitmweb: http://localhost:8081
# Frida:   adb shell su -c '/opt/anti-emu/frida-server -D &'
#          frida-ps -H localhost:5555
```

### GPU Accelerated (NVIDIA)

```bash
docker run -d --name android-gpu \
  --device /dev/kvm --gpus all \
  -p 5555:5555 \
  -e GPU_ACCELERATED=true \
  -e MEMORY=8192 -e CORES=4 \
  -v gpu-data:/data \
  ghcr.io/dhava-gautama/docker-android-lite:api-34-cuda
```

### Multi-Device Farm

```bash
docker run -d --name farm-30 --device /dev/kvm \
  -p 5561:5555 -e MEMORY=2048 -e CORES=1 \
  ghcr.io/dhava-gautama/docker-android-lite:api-30

docker run -d --name farm-33 --device /dev/kvm \
  -p 5563:5555 -e MEMORY=2048 -e CORES=1 \
  ghcr.io/dhava-gautama/docker-android-lite:api-33

docker run -d --name farm-34 --device /dev/kvm \
  -p 5565:5555 -e MEMORY=2048 -e CORES=1 \
  ghcr.io/dhava-gautama/docker-android-lite:api-34

# adb connect localhost:5561  (Android 11)
# adb connect localhost:5563  (Android 13)
# adb connect localhost:5565  (Android 14)
```

### Docker Compose

```yaml
services:
  android:
    image: ghcr.io/dhava-gautama/docker-android-lite:api-34
    devices: [/dev/kvm]
    ports: ["5555:5555"]
    environment:
      MEMORY: 4096
      CORES: 2
      HEADLESS: "true"
    volumes: [android-data:/data]
    restart: unless-stopped

volumes:
  android-data:
```

## Headless Optimizations

When `HEADLESS=true` (default), the emulator runs with aggressive optimizations:

**Emulator flags:**
- `-no-window -no-qt` — no display, no Qt framework (~50 MB RAM saved)
- `-no-audio` — no audio subsystem
- `-lowram` — triggers Android low-RAM mode (fewer cached processes)
- `-camera-back none -camera-front none` — no camera emulation
- `-no-cache` — skip /cache partition
- `-no-passive-gps` — no background GPS updates
- `-vsync-rate 15` — render at 15fps instead of 60fps
- `-delay-adb` — defer ADB until boot completes (faster boot)
- `-detect-image-hang` — auto-detect stuck emulator
- `-qemu -append panic=1` — auto-reboot on kernel panic

**Hardware config (disabled in AVD):**
gyroscope, humidity, light, magnetic field, orientation, pressure, proximity, temperature sensors, audio I/O, GPS, back camera

**Advanced features (disabled):**
ScreenRecording, VirtualScene, ModemSimulator, VirtioSndCard, TvRemote, Car*, MultiDisplay

**Post-boot tuning:**
- All animations disabled
- Google bloat disabled (22 packages)
- Non-essential processes force-stopped (17 packages)
- `max_cached_processes=4`
- Page cache dropped
- Background network restricted
- Device idle disabled (keeps ADB responsive)
- Hidden API policy unlocked

**Result:** ~3% idle CPU, ~1.5 GB idle RAM on `api-34-lite`.

## Boot State Logging

The entrypoint emits JSON state updates for orchestration:

```json
{"type":"state-update","value":"ANDROID_STARTING"}
{"type":"state-update","value":"ANDROID_BOOTING"}
{"type":"state-update","value":"ANDROID_READY"}
{"type":"state-update","value":"ANDROID_STOPPED"}
```

Wait for ready in a script:
```bash
docker logs -f android 2>&1 | grep -m1 "ANDROID_READY"
```

## ADB Keys

The image ships with a shared ADB keypair. Copy `keys/adbkey` to your client for auth-free connections:

```bash
# Get the key from the repo
cp keys/adbkey ~/.android/adbkey

# Or generate your own
adb keygen keys/adbkey
docker build -t android-lite .
```

## Pro Features

### Magisk Root (`ROOTED=true`)

Automated rootAVD patching — zero interaction required:
1. First boot: emulator starts unrooted
2. rootAVD patches ramdisk with Magisk
3. Cold restart with patched ramdisk
4. Magisk app installed, shell root auto-granted
5. Persists across container restarts (volume-backed)

```bash
# Verify root
adb shell su -c id
# uid=0(root) gid=0(root)
```

### Anti-Emulator (`STRONGERANTIEMU=true`)

Two-tier system controlled by env vars:

| Check | Default | `STRONGERANTIEMU=true` |
|-------|---------|----------------------|
| Build.prop spoofing | Pixel identity | + resetprop runtime patches |
| File hiding | Basic emulator files | + Zygisk-Assistant |
| Play Integrity | — | + TrickyStore + PlayIntegrityFork |
| Android ID | Randomized | Randomized |

### SSL Interception (`SSLBYPASS=true`)

Transparent HTTPS interception:
- **mitmweb** on port 8081 (web UI for traffic inspection)
- **AlwaysTrustUserCerts** Zygisk module (promotes user CA to system)
- Works with most apps that use standard certificate verification

### Frida Server

Pre-staged at `/opt/anti-emu/frida-server`. Start manually:
```bash
adb shell su -c '/opt/anti-emu/frida-server -D &'
frida-ps -H <host>:5555
```

### ARM App Support

The `google_apis` system images include **libndk_translation** (Google's ARM translation layer). ARM-only apps run out of the box on x86_64 — no extra setup needed.

## What's Included

| Component | Details |
|-----------|---------|
| Android emulator | KVM-accelerated, API 30/33/34 |
| ADB | Port 5555, shared keys |
| scrcpy | `scrcpy -s <host>:5555` |
| Magisk + rootAVD | Automated root, su auto-grant |
| Zygisk-Assistant | Hide root/emulator from apps |
| TrickyStore | Keystore-level attestation bypass |
| PlayIntegrityFork | Pass Play Integrity checks |
| AlwaysTrustUserCerts | System-level CA injection |
| Frida server | Dynamic instrumentation |
| mitmproxy/mitmweb | HTTPS traffic interception |
| Aurora Store | Play Store alternative |
| HEALTHCHECK | `adb shell getprop sys.boot_completed` every 30s |

## What's NOT Included

Keeps the image small (~2.5 GB vs ~8 GB alternatives):

| Excluded | Size saved | Alternative |
|----------|-----------|-------------|
| Appium | ~500 MB | ADB directly |
| noVNC | ~100 MB | scrcpy |
| Selenium | ~200 MB | ADB + scrcpy |
| Node.js | ~200 MB | Not needed |
| supervisord | ~50 MB | Direct exec entrypoint |

## Building

```bash
# Standard (google_apis, supports adb root)
docker build --build-arg API_LEVEL=34 -t android-lite:api-34 .

# Lite (AOSP, no Google services)
docker build --build-arg API_LEVEL=34 --build-arg IMG_TYPE=default \
  -t android-lite:api-34-lite .

# Native Play Store (no adb root)
docker build --build-arg API_LEVEL=34 --build-arg IMG_TYPE=google_apis_playstore \
  -t android-lite:api-34-gplaystore .

# NVIDIA GPU
docker build -f Dockerfile.gpu --build-arg API_LEVEL=34 \
  -t android-lite:api-34-cuda .

# Minimal (no SDK, mount externally)
docker build --build-arg INSTALL_ANDROID_SDK=0 \
  -t android-lite:minimal .
```

## Troubleshooting

| Problem | Fix |
|---------|-----|
| `adb connect` shows `offline` | Device may be in doze mode. Set `HEADLESS=true` (disables doze). Check `docker logs` for `ANDROID_READY`. |
| Emulator exits with code 1 | Check `docker logs` for `unknown option`. An emulator flag may be unsupported. |
| Boot timeout (>300s) | Increase `MEMORY` (minimum 2048). Check KVM: `ls /dev/kvm`. |
| `adb root` fails | Using `google_apis_playstore` image (production-signed). Switch to `google_apis` tag or use Magisk root. |
| Apps detect emulator | Enable `STRONGERANTIEMU=true`. For banking apps, also need `ROOTED=true` for Zygisk modules. |
| SSL pinning blocks mitmproxy | Enable `SSLBYPASS=true`. For certificate-pinned apps, use Frida scripts. |
| Container restarts in loop | Check `docker logs`. Likely a crash — try with `EXTRA_FLAGS="-show-kernel"` for kernel logs. |
| Play Store missing | Use `-gplaystore` tag for native Play Store, or `-playstore` tag for Aurora Store. |

## License

MIT

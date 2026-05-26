# docker-android-lite

Lightweight Android emulator in Docker. ~2.5 GB compressed — no bloat, just the emulator.

## Features

- **Small**: ~2.5 GB (vs 8 GB for full-featured alternatives)
- **Magisk root**: Automated rootAVD + auto-grant, zero interaction
- **Anti-emulator bypass**: Pixel 8 identity spoof, Zygisk modules, TrickyStore, PlayIntegrityFork
- **SSL interception**: mitmweb + AlwaysTrustUserCerts, WireGuard mode
- **Frida server**: Pre-staged, ready for dynamic instrumentation
- **Aurora Store**: Play Store alternative (install any app from Google Play)
- **CUDA GPU support**: Hardware-accelerated rendering via NVIDIA GPUs
- **scrcpy built-in**: View/control emulator from any machine
- **Headless-first**: Optimized for CI/CD and automation
- **Persistent data**: Volume mount for AVD state across restarts
- **KVM accelerated**: Near-native performance
- **Shared ADB keys**: Auth-free `adb connect` from any machine with the key
- **HEALTHCHECK**: Built-in Docker health monitoring

## Quick Start

```bash
docker run -d --name android \
  --device /dev/kvm \
  -p 5555:5555 \
  -v android-data:/data \
  ghcr.io/dhava-gautama/docker-android-lite:api-34
```

Connect via ADB:
```bash
adb connect <host>:5555
```

View screen via scrcpy:
```bash
scrcpy -s <host>:5555
```

## Image Tags

### Flavors

| Flavor | System Image | `adb root` | Google Services | Idle CPU | Idle RAM |
|--------|-------------|------------|-----------------|----------|----------|
| `default` (-lite) | AOSP only | Yes | None | ~3-4% | ~1.5 GB |
| `google_apis` | Dev-signed | Yes | Yes + Aurora Store | ~9% | ~5 GB |
| `google_apis_playstore` | Production-signed | No | Yes + native Play Store | ~9% | ~5 GB |

### Tags

| Tag | Flavor | Description |
|-----|--------|-------------|
| `api-34-lite` | default | Android 14, no Google — lightest |
| `api-30-lite` | default | Android 11, no Google — lightest |
| `api-34` | google_apis | Android 14 + Google services |
| `api-34-playstore` | google_apis | Android 14 + Aurora Store |
| `api-34-gplaystore` | google_apis_playstore | Android 14 + native Play Store |
| `api-34-cuda` | google_apis | Android 14 + NVIDIA GPU |
| `api-34-playstore-cuda` | google_apis | Android 14 + Aurora Store + GPU |
| `api-34-gplaystore-cuda` | google_apis_playstore | Android 14 + native Play Store + GPU |
| `api-34-minimal` | — | No SDK — mount via volume |

## Usage

### Headless (default)

```bash
docker run -d --name android \
  --device /dev/kvm \
  -p 5555:5555 \
  -e MEMORY=4096 \
  -e CORES=2 \
  -v android-data:/data \
  --restart unless-stopped \
  ghcr.io/dhava-gautama/docker-android-lite:api-34

# Connect
adb connect localhost:5555
adb shell
```

### Full setup (root + anti-emu + SSL interception)

```bash
docker run -d --name android \
  --device /dev/kvm \
  -p 5555:5555 -p 8081:8081 \
  -e MEMORY=8192 \
  -e CORES=4 \
  -e ROOTED=true \
  -e STRONGERANTIEMU=true \
  -e SSLBYPASS=true \
  -v android-data:/data \
  ghcr.io/dhava-gautama/docker-android-lite:api-34-playstore

# ADB: adb connect <host>:5555
# Screen: scrcpy -s <host>:5555
# mitmweb: http://<host>:8081 (password: mitmweb)
```

### Docker Compose

```yaml
services:
  android:
    image: ghcr.io/dhava-gautama/docker-android-lite:api-34-playstore
    container_name: android-lite
    devices:
      - /dev/kvm
    group_add:
      - "993"  # KVM group ID (check: stat -c '%g' /dev/kvm)
    ports:
      - "5555:5555"
      - "8081:8081"
    environment:
      - MEMORY=8192
      - CORES=4
      - HEADLESS=true
      - ROOTED=true
      - STRONGERANTIEMU=true
      - SSLBYPASS=true
    volumes:
      - android-data:/data
      - magisk-data:/opt/magisk
      - antiemu-data:/opt/anti-emu
      - ssl-data:/opt/ssl-bypass
    restart: unless-stopped

volumes:
  android-data:
  magisk-data:
  antiemu-data:
  ssl-data:
```

```bash
docker compose up -d
```

### With scrcpy (view screen)

```bash
adb connect <host>:5555
scrcpy -s <host>:5555
```

### GPU accelerated (NVIDIA)

```bash
docker run -d --name android-gpu \
  --device /dev/kvm \
  --gpus all \
  -p 5555:5555 \
  -e GPU_ACCELERATED=true \
  -e MEMORY=8192 \
  -e CORES=4 \
  -v android-data:/data \
  ghcr.io/dhava-gautama/docker-android-lite:api-34-cuda
```

## ADB Keys

The image ships with a shared ADB keypair in `keys/`. Copy `keys/adbkey` to `~/.android/adbkey` on your client machine for auth-free `adb connect`:

```bash
# Linux/macOS
cp keys/adbkey ~/.android/adbkey

# Windows (PowerShell)
copy keys\adbkey $env:USERPROFILE\.android\adbkey
```

Or generate your own and rebuild:
```bash
adb keygen keys/adbkey
docker build -t android-lite .
```

## Environment Variables

| Variable | Default | Description |
|----------|---------|-------------|
| `MEMORY` | `4096` | Emulator RAM (MB) |
| `CORES` | `2` | CPU cores |
| `DEVICE_ID` | `pixel` | AVD device profile |
| `HEADLESS` | `true` | No window/audio |
| `GPU_ACCELERATED` | `false` (`true` for CUDA) | Use host GPU |
| `EXTRA_FLAGS` | — | Additional emulator flags |
| `INSTALL_ANDROID_SDK` | `1` | Set to `0` for minimal image |
| `ROOTED` | `false` | Magisk root via rootAVD |
| `STRONGERANTIEMU` | `false` | Anti-emulator (Zygisk + resetprop + PIF) |
| `SSLBYPASS` | `false` | SSL interception (mitmweb on :8081) |

## What's Included

| Component | Details |
|-----------|---------|
| Android emulator + SDK | KVM-accelerated, API 30-35 |
| ADB | Port 5555, shared keys for auth-free connect |
| scrcpy | View/control from any machine |
| Magisk root | rootAVD, auto-grant su, post-fs-data.d persistence |
| Anti-emulator bypass | Pixel 8 spoof, Zygisk-Assistant, TrickyStore, PlayIntegrityFork |
| SSL interception | mitmweb (WireGuard mode), AlwaysTrustUserCerts |
| Frida server | Pre-staged: `adb shell su -c '/opt/anti-emu/frida-server -D &'` |
| Aurora Store | Play Store alternative (google_apis images) |
| CUDA/GPU rendering | NVIDIA GPU support (cuda tag) |
| HEALTHCHECK | Built-in Docker health monitoring |

## What's NOT Included (keeps it small)

| Component | Why excluded | Alternative |
|-----------|-------------|-------------|
| Appium | Saves ~500 MB | ADB directly |
| noVNC web UI | Saves ~100 MB | scrcpy |
| Selenium | Saves ~200 MB | ADB + scrcpy |
| Node.js | Saves ~200 MB | Not needed |

## Building

```bash
# google_apis (supports adb root)
docker build --build-arg API_LEVEL=34 -t android-lite:api-34 .

# google_apis + Aurora Store
docker build --build-arg API_LEVEL=34 -t android-lite:api-34-playstore .

# google_apis_playstore (native Play Store, no adb root)
docker build --build-arg API_LEVEL=34 --build-arg IMG_TYPE=google_apis_playstore \
  -t android-lite:api-34-gplaystore .

# GPU variant (google_apis)
docker build -f Dockerfile.gpu --build-arg API_LEVEL=34 -t android-lite:api-34-cuda .

# GPU variant (google_apis_playstore)
docker build -f Dockerfile.gpu --build-arg API_LEVEL=34 --build-arg IMG_TYPE=google_apis_playstore \
  -t android-lite:api-34-gplaystore-cuda .

# Minimal (no SDK, 500 MB)
docker build --build-arg INSTALL_ANDROID_SDK=0 -t android-lite:minimal .
```

## License

MIT

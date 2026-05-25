# docker-android-lite

Lightweight Android emulator in Docker. ~2.5 GB compressed — no bloat, just the emulator.

## Features

- **Small**: ~2.5 GB (vs 8 GB for full-featured alternatives)
- **CUDA GPU support**: Hardware-accelerated rendering via NVIDIA GPUs
- **scrcpy built-in**: View/control emulator from any machine
- **Headless-first**: Optimized for CI/CD and automation
- **Persistent data**: Volume mount for AVD state across restarts
- **KVM accelerated**: Near-native performance
- **PlayStore variants**: Google Play Store pre-installed
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

| Tag | Size | Description |
|-----|------|-------------|
| `api-34` | ~2.5 GB | Android 14, headless |
| `api-35` | ~2.5 GB | Android 15, headless |
| `api-33` | ~2.4 GB | Android 13, headless |
| `api-30` | ~2.3 GB | Android 11, headless |
| `api-34-playstore` | ~2.6 GB | Android 14 + Play Store |
| `api-34-cuda` | ~2.3 GB | Android 14 + NVIDIA GPU |
| `api-34-playstore-cuda` | ~2.4 GB | Android 14 + Play Store + GPU |
| `api-34-minimal` | ~500 MB | No SDK — mount via volume |

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

### With scrcpy (view screen)

```bash
# Start emulator
docker run -d --name android \
  --device /dev/kvm \
  -p 5555:5555 \
  -v android-data:/data \
  ghcr.io/dhava-gautama/docker-android-lite:api-34

# From your machine (install scrcpy first)
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

### Play Store

```bash
docker run -d --name android \
  --device /dev/kvm \
  -p 5555:5555 \
  -v android-data:/data \
  ghcr.io/dhava-gautama/docker-android-lite:api-34-playstore
```

### With display (non-headless)

```bash
docker run -d --name android \
  --device /dev/kvm \
  -p 5555:5555 \
  -e HEADLESS=false \
  -v android-data:/data \
  ghcr.io/dhava-gautama/docker-android-lite:api-34

# View via scrcpy
scrcpy -s localhost:5555
```

### Docker Compose

```bash
docker compose up android       # CPU headless
docker compose up android-gpu   # NVIDIA GPU
docker compose up android-playstore  # Play Store
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
| **Pro features** | | |
| `ROOTED` | `false` | Enable Magisk root (playstore images) |
| `STRONGERANTIEMU` | `false` | Anti-emulator (Zygisk + resetprop + PIF) |
| `SSLBYPASS` | `false` | SSL interception (mitmweb on :8081) |

## Persistent Data

Mount `/data` for AVD persistence:
```bash
-v my-volume:/data
```

Without a volume, the AVD is recreated on each start.

## What's Included

| Component | Included |
|-----------|----------|
| Android emulator + SDK | Yes |
| ADB (port 5555) | Yes |
| scrcpy | Yes |
| KVM acceleration | Yes |
| CUDA/GPU rendering | Yes (gpu tag) |
| HEALTHCHECK | Yes |
| Magisk root | Yes (`ROOTED=true`) |
| Anti-emulator bypass | Yes (`STRONGERANTIEMU=true`) |
| SSL interception (mitmweb) | Yes (`SSLBYPASS=true`) |
| Frida server | Yes (pre-staged) |
| Zygisk modules | Yes (Assistant, TrickyStore, PIF) |

## Pro Features (built-in)

All pro features from docker-android-pro are included, controlled by env vars:

| Feature | Env Var | Description |
|---------|---------|-------------|
| **Magisk root** | `ROOTED=true` | rootAVD + auto-grant (playstore images) |
| **Anti-emulator** | `STRONGERANTIEMU=true` | Zygisk modules + resetprop Pixel 8 spoof |
| **SSL interception** | `SSLBYPASS=true` | mitmweb + AlwaysTrustUserCerts (port 8081) |
| **Frida** | Pre-staged | Manual start: `adb shell su -c '/opt/anti-emu/frida-server -D &'` |

```bash
# Full stealth: root + anti-emu + SSL interception
docker run -d --device /dev/kvm -p 5555:5555 -p 8081:8081 \
  -e ROOTED=true -e STRONGERANTIEMU=true -e SSLBYPASS=true \
  -v data:/data \
  ghcr.io/dhava-gautama/docker-android-lite:api-34-playstore

# mitmweb UI: http://<host>:8081 (password: mitmweb)
```

## What's NOT Included (keeps it small)

| Component | Why excluded | Alternative |
|-----------|-------------|-------------|
| Appium | Saves ~500 MB | ADB directly |
| noVNC web UI | Saves ~100 MB | scrcpy |
| Selenium | Saves ~200 MB | ADB + scrcpy |
| Node.js | Saves ~200 MB | Not needed |

## Building

```bash
# CPU variant
docker build --build-arg API_LEVEL=34 -t android-lite:api-34 .

# GPU variant
docker build -f Dockerfile.gpu --build-arg API_LEVEL=34 -t android-lite:api-34-cuda .

# PlayStore
docker build --build-arg API_LEVEL=34 --build-arg IMG_TYPE=google_apis_playstore \
  -t android-lite:api-34-playstore .

# Minimal (no SDK, 500 MB)
docker build --build-arg INSTALL_ANDROID_SDK=0 -t android-lite:minimal .
```

## License

MIT

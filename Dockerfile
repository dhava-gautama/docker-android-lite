FROM eclipse-temurin:21-jre

ARG INSTALL_ANDROID_SDK=1
ARG API_LEVEL=34
ARG IMG_TYPE=google_apis
ARG ARCHITECTURE=x86_64
ARG CMD_LINE_VERSION=11076708_latest
ARG DEVICE_ID=pixel
ARG SCRCPY_VERSION=3.2

ENV DEBIAN_FRONTEND=noninteractive
ENV ANDROID_SDK_ROOT=/opt/android \
    ANDROID_PLATFORM_VERSION="platforms;android-$API_LEVEL" \
    PACKAGE_PATH="system-images;android-${API_LEVEL};${IMG_TYPE};${ARCHITECTURE}" \
    API_LEVEL=$API_LEVEL \
    DEVICE_ID=$DEVICE_ID \
    ARCHITECTURE=$ARCHITECTURE \
    ABI=${IMG_TYPE}/${ARCHITECTURE} \
    GPU_ACCELERATED=false \
    HEADLESS=true \
    ANDROID_AVD_HOME=/data \
    QTWEBENGINE_DISABLE_SANDBOX=1

ENV PATH="${PATH}:${ANDROID_SDK_ROOT}/platform-tools:${ANDROID_SDK_ROOT}/emulator:${ANDROID_SDK_ROOT}/cmdline-tools/tools/bin"
ENV LD_LIBRARY_PATH="$ANDROID_SDK_ROOT/emulator/lib64:$ANDROID_SDK_ROOT/emulator/lib64/qt/lib"

# Install minimal dependencies + scrcpy
RUN apt-get update && apt-get install -y --no-install-recommends \
        wget unzip socat iproute2 \
        libdrm2 libgbm1 libasound2 libnss3 \
        libxkbcommon0 libxshmfence1 libpulse0 \
        libdbus-glib-1-2 libxcursor1 \
        xvfb \
        scrcpy \
    && rm -rf /var/lib/apt/lists/*

WORKDIR /opt
EXPOSE 5554 5555

# Setup AVD home
RUN mkdir -p /root/.android /data \
    && touch /root/.android/repositories.cfg

# Install SDK
COPY scripts/install-sdk.sh /opt/
RUN chmod +x /opt/install-sdk.sh && /opt/install-sdk.sh

# Cleanup SDK cache
RUN rm -rf /tmp/* "$ANDROID_SDK_ROOT/.android" 2>/dev/null; true

# Entrypoint
COPY scripts/start-emulator.sh /opt/
RUN chmod +x /opt/start-emulator.sh

HEALTHCHECK --interval=30s --timeout=10s --retries=3 \
    CMD adb shell getprop sys.boot_completed 2>/dev/null | grep -q 1 || exit 1

ENTRYPOINT ["/opt/start-emulator.sh"]

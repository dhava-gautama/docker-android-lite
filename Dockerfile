FROM eclipse-temurin:21-jre

ARG INSTALL_ANDROID_SDK=1
ARG API_LEVEL=34
ARG IMG_TYPE=google_apis
ARG ARCHITECTURE=x86_64
ARG CMD_LINE_VERSION=11076708_latest
ARG DEVICE_ID=pixel
ARG FRIDA_VERSION=16.7.19

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

# Pro feature flags
ENV ROOTED=false \
    STRONGERANTIEMU=false \
    SSLBYPASS=false

ENV PATH="${PATH}:${ANDROID_SDK_ROOT}/platform-tools:${ANDROID_SDK_ROOT}/emulator:${ANDROID_SDK_ROOT}/cmdline-tools/tools/bin"
ENV LD_LIBRARY_PATH="$ANDROID_SDK_ROOT/emulator/lib64:$ANDROID_SDK_ROOT/emulator/lib64/qt/lib"

# Install minimal dependencies + scrcpy
RUN apt-get update && apt-get install -y --no-install-recommends \
        python3 python3-venv python3-pip \
        wget unzip socat iproute2 openssl xz-utils git lzip \
        libdrm2 libgbm1 libasound2t64 libnss3 \
        libxkbcommon0 libxshmfence1 libpulse0 \
        libdbus-glib-1-2 libxcursor1 libx11-6 libx11-xcb1 \
        xvfb scrcpy \
    && rm -rf /var/lib/apt/lists/*

# Install mitmproxy in virtualenv (for SSLBYPASS)
RUN python3 -m venv /opt/mitmproxy-venv \
    && /opt/mitmproxy-venv/bin/pip install --no-cache-dir mitmproxy \
    && ln -sf /opt/mitmproxy-venv/bin/mitmweb /usr/local/bin/mitmweb \
    && ln -sf /opt/mitmproxy-venv/bin/mitmdump /usr/local/bin/mitmdump

WORKDIR /opt
EXPOSE 5554 5555 8081

# Setup AVD home + shared ADB keys (same key on emulator + client = no auth prompt)
RUN mkdir -p /root/.android /data \
    && touch /root/.android/repositories.cfg
COPY keys/adbkey /root/.android/adbkey
COPY keys/adbkey.pub /root/.android/adbkey.pub
RUN chmod 600 /root/.android/adbkey

# Install SDK
COPY scripts/install-sdk.sh /opt/scripts/
RUN chmod +x /opt/scripts/install-sdk.sh && /opt/scripts/install-sdk.sh

# Stage Frida server
RUN mkdir -p /opt/anti-emu \
    && wget -q -L "https://github.com/frida/frida/releases/download/${FRIDA_VERSION}/frida-server-${FRIDA_VERSION}-android-x86_64.xz" \
         -O /tmp/frida-server.xz \
    && xz -d /tmp/frida-server.xz \
    && mv /tmp/frida-server /opt/anti-emu/frida-server \
    && chmod 755 /opt/anti-emu/frida-server

# Stage Zygisk modules (x86_64 compatible ones)
RUN wget -q -L "https://github.com/snake-4/Zygisk-Assistant/releases/download/v2.1.4/Zygisk-Assistant-v2.1.4-1013f8a-release.zip" \
        -O /opt/anti-emu/ZygiskAssistant.zip \
    && wget -q -L "https://github.com/5ec1cff/TrickyStore/releases/download/1.4.1/Tricky-Store-v1.4.1-245-72b2e84-release.zip" \
        -O /opt/anti-emu/TrickyStore.zip \
    && wget -q -L "https://github.com/osm0sis/PlayIntegrityFork/releases/download/v16/PlayIntegrityFork-v16.zip" \
        -O /opt/anti-emu/PlayIntegrityFork.zip

# Stage SSL bypass modules
RUN mkdir -p /opt/ssl-bypass \
    && wget -q -L "https://github.com/NVISOsecurity/AlwaysTrustUserCerts/releases/download/v1.3/AlwaysTrustUserCerts_v1.3.zip" \
        -O /opt/ssl-bypass/AlwaysTrustUserCerts.zip

# Install rootAVD (for Magisk on playstore images)
RUN git clone --depth 1 https://gitlab.com/newbit/rootAVD.git /opt/magisk/rootAVD \
    && rm -rf /opt/magisk/rootAVD/.git

# Copy all scripts
COPY scripts/ /opt/scripts/
RUN chmod +x /opt/scripts/*.sh

# Cleanup
RUN rm -rf /tmp/* /var/lib/apt/lists/* "$ANDROID_SDK_ROOT/.android" 2>/dev/null; \
    apt-get -qq remove git 2>/dev/null; apt-get -qq autoremove 2>/dev/null; true

HEALTHCHECK --interval=30s --timeout=10s --retries=3 \
    CMD adb shell getprop sys.boot_completed 2>/dev/null | grep -q 1 || exit 1

ENTRYPOINT ["/opt/scripts/start-emulator.sh"]

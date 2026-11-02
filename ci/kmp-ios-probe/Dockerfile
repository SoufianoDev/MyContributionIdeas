FROM ubuntu:24.04

ARG DEBIAN_FRONTEND=noninteractive
ARG GRADLE_VERSION=9.7.0

ENV JAVA_HOME=/usr/lib/jvm/java-21-openjdk-amd64
ENV GRADLE_HOME=/opt/gradle/gradle-${GRADLE_VERSION}
ENV PATH=${GRADLE_HOME}/bin:${JAVA_HOME}/bin:${PATH}
ENV LANG=C.UTF-8
ENV LC_ALL=C.UTF-8
ENV KONAN_DATA_DIR=/root/.konan

RUN apt-get update \
    && apt-get install -y --no-install-recommends \
       ca-certificates \
       curl \
       unzip \
       zip \
       git \
       python3 \
       file \
       binutils \
       build-essential \
       clang \
       lld \
       openjdk-21-jdk-headless \
       libtinfo6 \
       libncurses6 \
       zlib1g \
       libstdc++6 \
    && rm -rf /var/lib/apt/lists/*

RUN set -eux; \
    curl -fsSLO "https://services.gradle.org/distributions/gradle-${GRADLE_VERSION}-bin.zip"; \
    curl -fsSLO "https://services.gradle.org/distributions/gradle-${GRADLE_VERSION}-bin.zip.sha256"; \
    echo "$(cat "gradle-${GRADLE_VERSION}-bin.zip.sha256")  gradle-${GRADLE_VERSION}-bin.zip" | sha256sum -c -; \
    mkdir -p /opt/gradle; \
    unzip -q "gradle-${GRADLE_VERSION}-bin.zip" -d /opt/gradle; \
    rm "gradle-${GRADLE_VERSION}-bin.zip" "gradle-${GRADLE_VERSION}-bin.zip.sha256"; \
    java -version; \
    gradle --version

WORKDIR /probe
ENTRYPOINT ["/bin/bash"]

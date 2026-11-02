FROM ubuntu:24.04

ARG DEBIAN_FRONTEND=noninteractive
ENV JAVA_HOME=/usr/lib/jvm/java-21-openjdk-amd64
ENV PATH=${JAVA_HOME}/bin:${PATH}
ENV LANG=C.UTF-8
ENV LC_ALL=C.UTF-8
ENV GRADLE_USER_HOME=/work/gradle-home
ENV KONAN_DATA_DIR=/work/konan-data
ENV GRADLE_OPTS=-Xmx8g\ -XX:MaxMetaspaceSize=2g\ -Dfile.encoding=UTF-8

RUN apt-get update \
    && apt-get install -y --no-install-recommends \
       ca-certificates curl git unzip zip python3 build-essential clang cmake ninja-build \
       pkg-config file binutils strace openjdk-21-jdk-headless libtinfo6 libncurses6 \
       zlib1g libstdc++6 libxml2-dev libedit-dev libzstd-dev libffi-dev \
       libcurl4-openssl-dev libssl-dev liblzma-dev \
    && rm -rf /var/lib/apt/lists/*

RUN java -version && clang++ --version && cmake --version && strace --version
WORKDIR /work
ENTRYPOINT ["/bin/bash"]

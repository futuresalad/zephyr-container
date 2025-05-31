ARG DEBIAN_VERSION=stable-20241016-slim

# Use Debian as the base image
FROM debian:${DEBIAN_VERSION}

# Settings
ARG PASSWORD="zephyr"
ARG ZEPHYR_RTOS_VERSION=4.1.0
ARG ZEPHYR_RTOS_COMMIT=7823374
ARG ZEPHYR_SDK_VERSION=0.17.1
ARG TOOLCHAIN_LIST="-t arm-zephyr-eabi"
ARG WGET_ARGS="-q --show-progress --progress=bar:force:noscroll"
ARG VIRTUAL_ENV=/opt/venv

# Set default shell during Docker image build to bash
SHELL ["/bin/bash", "-c"]

# Set non-interactive frontend for apt-get to skip any user confirmations
ENV DEBIAN_FRONTEND=noninteractive

# Install base packages
RUN apt-get -y update && \
	apt-get install --no-install-recommends -y \
		software-properties-common \
		lsb-release \
		autoconf \
		automake \
		bison \
		build-essential \
		ca-certificates \
		ccache \
		chrpath \
		cmake \
		cpio \
		device-tree-compiler \
		dfu-util \
		diffstat \
		dos2unix \
		doxygen \
		file \
		flex \
		g++ \
		gawk \
		gcc \
		gcovr \
		gdb \
		git \
		git-core \
		gnupg \
		gperf \
		help2man \
		iproute2 \
		lcov \
		libcairo2-dev \
		libglib2.0-dev \
		libgtk2.0-0 \
		liblocale-gettext-perl \
		libncurses5-dev \
		libpcap-dev \
		libpopt0 \
		libsdl1.2-dev \
		libsdl2-dev \
		libssl-dev \
		libtool \
		libtool-bin \
		locales \
		make \
		net-tools \
		ninja-build \
		openssh-client \
		parallel \
		pkg-config \
		python3-dev \
		python3-pip \
		python3-ply \
		python3-setuptools \
		python-is-python3 \
		python3-venv \
		rsync \
		socat \
		srecord \
		sudo \
		texinfo \
		unzip \
		valgrind \
		wget \
		ovmf \
        tree \
		xz-utils \
		thrift-compiler \
        sudo

# Initialise system locale
#RUN locale-gen en_US.UTF-8
#ENV LANG=en_US.UTF-8
#ENV LANGUAGE=en_US:en
#ENV LC_ALL=en_US.UTF-8

# Install multi-lib gcc (x86 only)
RUN if [ "${HOSTTYPE}" = "x86_64" ]; then \
	apt-get install --no-install-recommends -y \
		gcc-multilib \
		g++-multilib \
        libsdl2-dev \
        libfuse-dev \
	; fi

# Install i386 packages (x86 only)
RUN if [ "${HOSTTYPE}" = "x86_64" ]; then \
	dpkg --add-architecture i386 && \
	apt-get -y update && \
	apt-get -y upgrade && \
	apt-get install --no-install-recommends -y \
		libsdl2-dev:i386 libfuse-dev:i386 libc6-dbg:i386 python3\
	; fi


# Set up a Python virtual environment
ENV VIRTUAL_ENV=${VIRTUAL_ENV}
RUN python3 -m venv ${VIRTUAL_ENV}
ENV PATH="${VIRTUAL_ENV}/bin:$PATH"

# Install west
RUN python3 -m pip install --no-cache-dir west

# Clean up stale packages
RUN apt-get clean -y && \
    apt-get autoremove --purge -y && \
    rm -rf /var/lib/apt/lists/*

# Create a normal user
RUN useradd -m -s /bin/bash user && \
    echo "user:${PASSWORD}" | chpasswd && \
    usermod -aG sudo user

# Set up directories
RUN mkdir -p /remotews && \
    mkdir -p /opt/toolchains && \
    chown -R user:user /remotews /opt/toolchains /opt/venv

# Initialise system locale (required by menuconfig)
RUN sed -i '/^#.*en_US.UTF-8/s/^#//' /etc/locale.gen && \
    locale-gen en_US.UTF-8 && \
    update-locale LANG=en_US.UTF-8 LC_ALL=en_US.UTF-8

USER user
WORKDIR /remotews

# Set Zephyr environment variables
ENV ZEPHYR_RTOS_VERSION=${ZEPHYR_RTOS_VERSION}

# Install Zephyr
RUN cd /opt/toolchains && \
    git clone https://github.com/zephyrproject-rtos/zephyr.git && \
    cd zephyr && \
    git checkout ${ZEPHYR_RTOS_COMMIT} && \
    python3 -m pip install -r scripts/requirements-base.txt

# Instantiate west workspace and install tools
RUN cd /opt/toolchains && \
	west init -l zephyr && \
	west update --narrow -o=--depth=1

# Install module-specific blobs
RUN cd /opt/toolchains && \
    west blobs fetch hal_nordic hal_espressif hal_silabs

# Set environment variables
ENV ZEPHYR_SDK_VERSION=${ZEPHYR_SDK_VERSION}

# Install minimal Zephyr SDK
RUN cd /opt/toolchains && \
    wget ${WGET_ARGS} https://github.com/zephyrproject-rtos/sdk-ng/releases/download/v${ZEPHYR_SDK_VERSION}/zephyr-sdk-${ZEPHYR_SDK_VERSION}_linux-${HOSTTYPE}_minimal.tar.xz && \
    tar xf zephyr-sdk-${ZEPHYR_SDK_VERSION}_linux-${HOSTTYPE}_minimal.tar.xz && \
    rm zephyr-sdk-${ZEPHYR_SDK_VERSION}_linux-${HOSTTYPE}_minimal.tar.xz

# Install Zephyr SDK for the specified toolchains
RUN cd /opt/toolchains/zephyr-sdk-${ZEPHYR_SDK_VERSION} && \
    yes | bash setup.sh

# Install host tools
RUN cd /opt/toolchains/zephyr-sdk-${ZEPHYR_SDK_VERSION} && \
    wget ${WGET_ARGS} https://github.com/zephyrproject-rtos/sdk-ng/releases/download/v${ZEPHYR_SDK_VERSION}/hosttools_linux-${HOSTTYPE}.tar.xz && \
    tar xf hosttools_linux-${HOSTTYPE}.tar.xz && \
    rm hosttools_linux-${HOSTTYPE}.tar.xz && \
    bash zephyr-sdk-${HOSTTYPE}-hosttools-standalone-*.sh -y -d .

USER root
# Install udev if needed
RUN apt-get update && apt-get install -y udev && rm -rf /var/lib/apt/lists/*

# Install udev rules for OpenOCD (if file exists)
RUN if [ -f /opt/toolchains/zephyr-sdk-${ZEPHYR_SDK_VERSION}/sysroots/x86_64-pokysdk-linux/usr/share/openocd/contrib/60-openocd.rules ]; then \
        cp /opt/toolchains/zephyr-sdk-${ZEPHYR_SDK_VERSION}/sysroots/x86_64-pokysdk-linux/usr/share/openocd/contrib/60-openocd.rules /etc/udev/rules.d/; \
    fi

USER user
# Activate the Python and Zephyr environments for shell sessions
RUN echo "source ${VIRTUAL_ENV}/bin/activate" >> /home/user/.bashrc && \
    echo "source /opt/toolchains/zephyr/zephyr-env.sh" >> /home/user/.bashrc


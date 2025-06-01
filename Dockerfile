ARG DEBIAN_VERSION=stable-20241016-slim

# Use Debian as the base image
FROM debian:${DEBIAN_VERSION}

# Settings
ARG PASSWORD="zephyr"
ARG ZEPHYR_RTOS_VERSION=4.1.0
ARG ZEPHYR_RTOS_COMMIT=7823374
ARG ZEPHYR_SDK_VERSION=0.16.8
ARG TOOLCHAIN_LIST="-t arm-zephyr-eabi -t xtensa-espressif_esp32_zephyr-elf -t xtensa-espressif_esp32s2_zephyr-elf -t xtensa-espressif_esp32s3_zephyr-elf -t riscv64-zephyr-elf"
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
		libxcb1-dev \
		libxkbcommon-dev \
		libxcb-render0-dev \
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
    usermod -aG sudo user && \
	usermod -aG dialout user && \
	usermod -aG uucp user

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
    bash setup.sh -c ${TOOLCHAIN_LIST}

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

# nrfutil for norduc chips
RUN wget https://github.com/NordicSemiconductor/nrf-udev/releases/download/v1.0.1/nrf-udev_1.0.1-all.deb && \
	dpkg -i nrf-udev_1.0.1-all.deb && \
	rm nrf-udev_1.0.1-all.deb

RUN wget https://files.nordicsemi.com/artifactory/swtools/external/nrfutil/executables/x86_64-unknown-linux-gnu/nrfutil -O /usr/local/bin/nrfutil && \
    chmod +x /usr/local/bin/nrfutil

# Install JLink dependencies
RUN apt-get update && apt-get install --no-install-recommends -y \
    libxcb-render-util0 \
    libxcb-shape0 \
    libxcb-icccm4 \
    libxcb-keysyms1 \
    libxcb-image0 \
    libxkbcommon-x11-0 && \
    rm -rf /var/lib/apt/lists/*

# Install JLink tools and suppress udev errors
RUN wget -q -O /tmp/jlink.deb --post-data="non_emb_ctr=confirmed&accept_license_agreement=accepted&submit=Download software" https://www.segger.com/downloads/jlink/JLink_Linux_x86_64.deb && \
    (dpkg -i --force-depends /tmp/jlink.deb 2>/dev/null || \
     dpkg --configure -a 2>/dev/null || true) && \
    rm /tmp/jlink.deb

RUN export PATH="/opt/SEGGER/JLink:$PATH" && \
	echo 'export PATH="/opt/SEGGER/JLink:$PATH"' >> ~/.bashrc

USER user

# Install nrfutil
RUN nrfutil self-upgrade && \
	nrfutil install device && \
	nrfutil install nrf5sdk-tools && \
	nrfutil install completion

# Activate the Python and Zephyr environments for shell sessions
RUN echo "source ${VIRTUAL_ENV}/bin/activate" >> /home/user/.bashrc && \
    echo "source /opt/toolchains/zephyr/zephyr-env.sh" >> /home/user/.bashrc

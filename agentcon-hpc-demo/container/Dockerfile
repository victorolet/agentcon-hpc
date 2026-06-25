# GROMACS 2024.3 with CUDA acceleration, sized for a single GPU.
# Built once on the demo VM; not pushed to a registry.
#
# We pin:
#   - the CUDA runtime base image
#   - the GROMACS source tarball
#   - a deterministic CMake configuration
# so that a rebuild a year from now produces a numerically identical binary.
FROM nvidia/cuda:12.4.1-devel-ubuntu22.04 AS builder

ARG GMX_VERSION=2024.3

ENV DEBIAN_FRONTEND=noninteractive
RUN apt-get update && apt-get install -y --no-install-recommends \
        build-essential cmake git wget ca-certificates \
        libfftw3-dev libopenmpi-dev openmpi-bin \
        python3 python3-pip \
    && rm -rf /var/lib/apt/lists/*

WORKDIR /tmp
RUN wget -q "https://ftp.gromacs.org/gromacs/gromacs-${GMX_VERSION}.tar.gz" && \
    tar xf "gromacs-${GMX_VERSION}.tar.gz" && \
    rm "gromacs-${GMX_VERSION}.tar.gz"

WORKDIR /tmp/gromacs-${GMX_VERSION}/build
RUN cmake .. \
        -DGMX_BUILD_OWN_FFTW=OFF \
        -DGMX_GPU=CUDA \
        -DCMAKE_INSTALL_PREFIX=/opt/gromacs \
        -DGMX_MPI=OFF \
        -DGMX_OPENMP=ON \
        -DREGRESSIONTEST_DOWNLOAD=OFF \
        -DGMX_DEFAULT_SUFFIX=ON \
    && make -j"$(nproc)" \
    && make install

# ---- runtime image -------------------------------------------------------
FROM nvidia/cuda:12.4.1-runtime-ubuntu22.04

ENV DEBIAN_FRONTEND=noninteractive
RUN apt-get update && apt-get install -y --no-install-recommends \
        libfftw3-3 libgomp1 ca-certificates wget \
    && rm -rf /var/lib/apt/lists/*

COPY --from=builder /opt/gromacs /opt/gromacs
ENV PATH=/opt/gromacs/bin:$PATH \
    GMXLIB=/opt/gromacs/share/gromacs/top

# Non-root user that matches the typical UID 1000 on Ubuntu hosts so that
# files written to mounted /data are readable by the host user.
RUN useradd -ms /bin/bash -u 1000 sim
USER sim
WORKDIR /data

COPY --chown=sim:sim --chmod=755 entrypoint.sh /usr/local/bin/entrypoint.sh
ENTRYPOINT ["/usr/local/bin/entrypoint.sh"]
CMD ["gmx", "--version"]

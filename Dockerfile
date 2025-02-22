# Use latest NVIDIA CUDA base image
FROM nvidia/cuda:12.3.2-devel-ubuntu22.04

# Set noninteractive installation
ENV DEBIAN_FRONTEND=noninteractive
ENV PYTHONUNBUFFERED=1

# Set working directory
WORKDIR /workspace

# Install system dependencies including Ceres and FLANN
RUN apt-get update && apt-get install -y \
    cmake \
    ninja-build \
    build-essential \
    git \
    libboost-program-options-dev \
    libboost-filesystem-dev \
    libboost-graph-dev \
    libboost-system-dev \
    libboost-test-dev \
    libeigen3-dev \
    libsuitesparse-dev \
    libfreeimage-dev \
    libgoogle-glog-dev \
    libgflags-dev \
    libglew-dev \
    qtbase5-dev \
    libqt5opengl5-dev \
    libcgal-dev \
    libflann-dev \
    libceres-dev \
    libsqlite3-dev \
    libmetis-dev \
    python3-dev \
    python3-pip \
    ffmpeg \
    && rm -rf /var/lib/apt/lists/*

# Install basic Python packages
RUN pip3 install --no-cache-dir \
    numpy \
    scipy \
    matplotlib

# Clone and build COLMAP with CUDA
RUN git clone https://github.com/colmap/colmap.git && \
    cd colmap && \
    mkdir build && \
    cd build && \
    cmake .. \
    -GNinja \
    -DCMAKE_BUILD_TYPE=Release \
    -DCUDA_ENABLED=ON \
    -DCMAKE_CUDA_ARCHITECTURES="75;86;89" \
    -DCMAKE_CUDA_FLAGS="--use_fast_math" \
    -DCMAKE_CXX_FLAGS="-O2" \
    -DTESTS_ENABLED=OFF && \
    NINJA_STATUS="[%f/%t] " ninja -j2 && \
    ninja install && \
    cd ../.. && \
    rm -rf colmap

# Create a non-root user
RUN useradd -m -s /bin/bash pythonuser

# Ensure COLMAP is in PATH
ENV PATH="/usr/local/bin:$PATH"

# Copy run script
COPY run_colmap.sh /workspace/run_colmap.sh
RUN chmod +x /workspace/run_colmap.sh

# Set entrypoint to run script
ENTRYPOINT ["/workspace/run_colmap.sh"]
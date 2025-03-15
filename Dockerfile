# Use latest NVIDIA CUDA base image
FROM nvidia/cuda:12.3.2-devel-ubuntu22.04

# Set noninteractive installation
ENV DEBIAN_FRONTEND=noninteractive
ENV PYTHONUNBUFFERED=1

# Set working directory
WORKDIR /workspace

# First install minimal dependencies for building newer CMake
RUN apt-get update && apt-get install -y \
    build-essential \
    libssl-dev \
    wget \
    git \
    ninja-build \
    python3-dev \
    python3-pip \
    && rm -rf /var/lib/apt/lists/*

# Install latest CMake (required for GLOMAP)
RUN wget https://github.com/Kitware/CMake/releases/download/v3.28.3/cmake-3.28.3.tar.gz && \
    tar -zxvf cmake-3.28.3.tar.gz && \
    cd cmake-3.28.3 && \
    ./bootstrap --parallel=2 && \
    make -j2 && \
    make install && \
    cd .. && \
    rm -rf cmake-3.28.3 cmake-3.28.3.tar.gz

# Now install the rest of the dependencies
RUN apt-get update && apt-get install -y \
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
    ffmpeg \
    unzip \
    && rm -rf /var/lib/apt/lists/*

# Install basic Python packages
RUN pip3 install --no-cache-dir \
    numpy \
    scipy \
    matplotlib \
    torch \
    torchvision \
    tqdm \
    pillow \
    opencv-python

# Clone COLMAP
RUN git clone https://github.com/colmap/colmap.git

# Build COLMAP with reduced memory usage (one file at a time)
RUN cd colmap && \
    mkdir build && \
    cd build && \
    # Configure with minimal features to reduce build complexity
    cmake .. \
    -GNinja \
    -DCMAKE_BUILD_TYPE=Release \
    -DCUDA_ENABLED=ON \
    -DCMAKE_CUDA_ARCHITECTURES="75;86" \
    -DCMAKE_CUDA_FLAGS="--use_fast_math" \
    -DCMAKE_CXX_FLAGS="-O2 -DBOOST_BIND_GLOBAL_PLACEHOLDERS" \
    -DTESTS_ENABLED=OFF \
    -DGUI_ENABLED=OFF \
    -DCGAL_ENABLED=OFF \
    -DOPENGL_ENABLED=OFF \
    -DQTGL_ENABLED=OFF && \
    # Build with only 1 job to reduce memory usage
    NINJA_STATUS="[%f/%t] " ninja -j1 && \
    ninja install && \
    cd ../.. && \
    rm -rf colmap

# Clone GLOMAP repository
RUN git clone https://github.com/colmap/glomap.git && \
    cd glomap && \
    # Check what's inside the repository
    ls -la > /tmp/glomap_contents.txt && \
    # Save information about available files for debugging
    find . -type f -name "*.cpp" > /tmp/cpp_files.txt || true && \
    find . -type f -name "*.cc" >> /tmp/cpp_files.txt || true && \
    find . -type f -name "*.h" >> /tmp/cpp_files.txt || true && \
    find . -type f -name "*.py" > /tmp/py_files.txt || true && \
    # See if there are any executables
    find . -type f -executable > /tmp/executables.txt || true && \
    cd ..

# Attempt to build GLOMAP only if needed
RUN cd glomap && \
    if [ -f "CMakeLists.txt" ]; then \
        mkdir -p build && \
        cd build && \
        # Use minimal settings to reduce memory usage
        cmake .. -GNinja \
        -DCMAKE_BUILD_TYPE=Release \
        -DCMAKE_CXX_FLAGS="-O2 -DBOOST_BIND_GLOBAL_PLACEHOLDERS" && \
        # Build with only 1 job to reduce memory usage
        ninja -j1 && \
        ninja install || echo "GLOMAP build failed but continuing"; \
    fi && \
    cd ..

# Add GLOMAP to path if it exists in any of the expected locations
RUN if [ -d "/workspace/glomap/build/bin" ] && [ -f "/workspace/glomap/build/bin/glomap" ]; then \
        ln -s /workspace/glomap/build/bin/glomap /usr/local/bin/glomap; \
    elif [ -f "/workspace/glomap/glomap" ]; then \
        ln -s /workspace/glomap/glomap /usr/local/bin/glomap; \
    elif [ -f "/workspace/glomap/build/glomap" ]; then \
        ln -s /workspace/glomap/build/glomap /usr/local/bin/glomap; \
    elif [ -f "/usr/local/bin/glomap" ]; then \
        echo "GLOMAP already installed in /usr/local/bin"; \
    else \
        echo "GLOMAP binary not found. Will use COLMAP mapper instead."; \
    fi

# Create a non-root user
RUN useradd -m -s /bin/bash pythonuser

# Set proper environment variables (fix variable usage)
ENV PATH="/usr/local/bin:${PATH}"
ENV PYTHONPATH="/workspace:${PYTHONPATH:+:$PYTHONPATH}"

# Copy run script
COPY run_glomap.sh /workspace/run_glomap.sh
RUN chmod +x /workspace/run_glomap.sh

# Set entrypoint to run script
ENTRYPOINT ["/workspace/run_glomap.sh"]
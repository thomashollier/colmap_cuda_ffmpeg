#!/bin/bash
set -e  # Exit on error

# Check if config file is provided
if [ -z "$CONFIG_PATH" ]; then
    echo "Error: CONFIG_PATH environment variable not set"
    echo "Please run docker with: -e CONFIG_PATH=/workspace/config/colmap_config.ini"
    exit 1
fi

# Check if config file exists
if [ ! -f "$CONFIG_PATH" ]; then
    echo "Error: Config file not found at $CONFIG_PATH"
    echo "Make sure you mounted the directory containing your config file"
    exit 1
fi

# Read paths and settings from config file
INPUT_PATH=$(grep "^input_path=" "$CONFIG_PATH" | cut -d'=' -f2 | tr -d ' \t\r')
OUTPUT_PATH=$(grep "^output_path=" "$CONFIG_PATH" | cut -d'=' -f2 | tr -d ' \t\r')
DATABASE_PATH=$(grep "^database_path=" "$CONFIG_PATH" | cut -d'=' -f2 | tr -d ' \t\r')
VIDEO_PATH=$(grep "^video_path=" "$CONFIG_PATH" | cut -d'=' -f2 | tr -d ' \t\r')
FPS=$(grep "^frames_per_second=" "$CONFIG_PATH" | cut -d'=' -f2 | tr -d ' \t\r')
MATCHER_TYPE=$(grep "^matcher_type=" "$CONFIG_PATH" | cut -d'=' -f2 | tr -d ' \t\r')
STOP_AT_SPARSE=$(grep "^stop_at_sparse=" "$CONFIG_PATH" | cut -d'=' -f2 | tr -d ' \t\r')

# Check if video path is set and video exists
if [ ! -z "$VIDEO_PATH" ] && [ -f "$VIDEO_PATH" ]; then
    echo "Video found at $VIDEO_PATH"
    echo "Extracting frames at $FPS fps..."
    
    # Create images directory if it doesn't exist
    mkdir -p "$INPUT_PATH"
    
    # Extract frames using ffmpeg
    ffmpeg -i "$VIDEO_PATH" -vf "fps=$FPS" -frame_pts 1 "$INPUT_PATH/frame_%d.jpg"
    
    echo "Frame extraction complete"
fi

# Check if image directory exists
if [ ! -d "$INPUT_PATH" ]; then
    echo "Error: Image directory not found at $INPUT_PATH"
    echo "Make sure you mounted your image directory correctly"
    exit 1
fi

# Create output directories
SPARSE_PATH="$OUTPUT_PATH/sparse"
DENSE_PATH="$OUTPUT_PATH/dense"
mkdir -p "$OUTPUT_PATH"
mkdir -p "$SPARSE_PATH"
mkdir -p "$DENSE_PATH"

echo "Using config file: $CONFIG_PATH"
echo "Input path: $INPUT_PATH"
echo "Output path: $OUTPUT_PATH"
echo "Matcher type: $MATCHER_TYPE"
echo "Starting COLMAP pipeline..."

# Feature extraction
echo "1. Extracting features..."
colmap feature_extractor \
    --database_path "$DATABASE_PATH" \
    --image_path "$INPUT_PATH" \
    --ImageReader.camera_model SIMPLE_RADIAL \
    --ImageReader.single_camera 1 \
    --SiftExtraction.gpu_index 0 \
    --SiftExtraction.use_gpu 1

# Feature matching
echo "2. Matching features..."
if [ "$MATCHER_TYPE" = "sequential" ]; then
    echo "Using sequential matcher..."
    colmap sequential_matcher \
        --database_path "$DATABASE_PATH" \
        --SiftMatching.gpu_index 0 \
        --SiftMatching.use_gpu 1
else
    echo "Using exhaustive matcher..."
    colmap exhaustive_matcher \
        --database_path "$DATABASE_PATH" \
        --SiftMatching.gpu_index 0 \
        --SiftMatching.use_gpu 1
fi

# Sparse reconstruction
echo "3. Running sparse reconstruction..."
colmap mapper \
    --database_path "$DATABASE_PATH" \
    --image_path "$INPUT_PATH" \
    --output_path "$SPARSE_PATH"

if [ "$STOP_AT_SPARSE" = "true" ]; then
    echo "Stopping after sparse reconstruction as requested."
    echo "Sparse reconstruction can be found at: $SPARSE_PATH"
    exit 0
fi

# Dense reconstruction
echo "4. Running dense reconstruction..."
colmap image_undistorter \
    --image_path "$INPUT_PATH" \
    --input_path "$SPARSE_PATH/0" \
    --output_path "$DENSE_PATH" \
    --output_type COLMAP

colmap patch_match_stereo \
    --workspace_path "$DENSE_PATH" \
    --workspace_format COLMAP \
    --PatchMatchStereo.gpu_index 0

colmap stereo_fusion \
    --workspace_path "$DENSE_PATH" \
    --workspace_format COLMAP \
    --input_type geometric \
    --output_path "$DENSE_PATH/fused.ply"

# Meshing
echo "5. Creating mesh..."
mkdir -p "$DENSE_PATH/meshed"

# Create mesh from dense point cloud
colmap delaunay_mesher \
    --input_path "$DENSE_PATH" \
    --output_path "$DENSE_PATH/meshed/meshed.ply" \
    --DelaunayMeshing.quality_regularization 1.0 \
    --DelaunayMeshing.max_proj_dist 10.0

echo "COLMAP processing complete!"
echo "Final mesh can be found at: $DENSE_PATH/meshed/meshed.ply"

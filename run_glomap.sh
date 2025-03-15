#!/bin/bash
set -e  # Exit on error

# Create an array to store executed commands
COMMAND_HISTORY=()

# Check if config file is provided
if [ -z "$CONFIG_PATH" ]; then
    echo "Error: CONFIG_PATH environment variable not set"
    echo "Please run docker with: -e CONFIG_PATH=/workspace/config/glomap_config.ini"
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
NUM_WORKERS=$(grep "^num_workers=" "$CONFIG_PATH" | cut -d'=' -f2 | tr -d ' \t\r' || echo "1")
NUM_THREADS=$(grep "^num_threads=" "$CONFIG_PATH" | cut -d'=' -f2 | tr -d ' \t\r' || echo "-1")
SKIP_EXTRACTION=$(grep "^skip_extraction=" "$CONFIG_PATH" | cut -d'=' -f2 | tr -d ' \t\r' || echo "false")
SKIP_MATCHING=$(grep "^skip_matching=" "$CONFIG_PATH" | cut -d'=' -f2 | tr -d ' \t\r' || echo "false")
SKIP_MAPPING=$(grep "^skip_mapping=" "$CONFIG_PATH" | cut -d'=' -f2 | tr -d ' \t\r' || echo "false")
USE_COLMAP_MAPPER=$(grep "^use_colmap_mapper=" "$CONFIG_PATH" | cut -d'=' -f2 | tr -d ' \t\r' || echo "false")

# Function to execute command with echo
execute_command() {
    local cmd="$1"
    local description="$2"
    
    echo -e "\n------------------------------------------"
    echo "EXECUTING: $cmd"
    echo "------------------------------------------"
    
    # Store the command with description in history
    COMMAND_HISTORY+=("$description: $cmd")
    
    # Execute the command
    eval "$cmd"
    return $?
}

# Check if video path is set and video exists
if [ ! -z "$VIDEO_PATH" ] && [ -f "$VIDEO_PATH" ]; then
    echo "Video found at $VIDEO_PATH"
    echo "Extracting frames at $FPS fps..."
    
    # Create images directory if it doesn't exist
    mkdir -p "$INPUT_PATH"
    
    # Extract frames using ffmpeg (COLMAP step)
    FFMPEG_CMD="ffmpeg -i \"$VIDEO_PATH\" -vf \"fps=$FPS\" \"$INPUT_PATH/frame_%06d.jpg\""
    execute_command "$FFMPEG_CMD" "Frame extraction (ffmpeg)"
    
    echo "Frame extraction complete"
else
    echo "SKIPPED: No video found or video path not set. Skipping frame extraction."
fi

# Check if image directory exists
if [ ! -d "$INPUT_PATH" ]; then
    echo "Error: Image directory not found at $INPUT_PATH"
    echo "Make sure you mounted your image directory correctly"
    exit 1
fi

# Create output directories
SPARSE_PATH="$OUTPUT_PATH/sparse"
GLOMAP_PATH="$OUTPUT_PATH/glomap"
mkdir -p "$OUTPUT_PATH"
mkdir -p "$SPARSE_PATH"
mkdir -p "$GLOMAP_PATH"

echo "Using config file: $CONFIG_PATH"
echo "Input path: $INPUT_PATH"
echo "Output path: $OUTPUT_PATH"
echo "Matcher type: $MATCHER_TYPE"
echo "Mapper choice: $([ "$USE_COLMAP_MAPPER" = "true" ] && echo "COLMAP" || echo "GLOMAP (with COLMAP fallback)")"

# STEP 1: Feature extraction using COLMAP
if [ "$SKIP_EXTRACTION" = "true" ] && [ -f "$DATABASE_PATH" ]; then
    echo "SKIPPED: Feature extraction (skip_extraction=true and database exists)"
else
    echo "1. Extracting features (COLMAP)..."
    FEATURE_CMD="colmap feature_extractor \\
        --database_path \"$DATABASE_PATH\" \\
        --image_path \"$INPUT_PATH\" \\
        --ImageReader.camera_model SIMPLE_RADIAL \\
        --ImageReader.single_camera 1 \\
        --SiftExtraction.gpu_index 0 \\
        --SiftExtraction.use_gpu 1"
        
    execute_command "$FEATURE_CMD" "Feature extraction (COLMAP)"
fi

# STEP 2: Feature matching using COLMAP
if [ "$SKIP_MATCHING" = "true" ]; then
    echo "SKIPPED: Feature matching (skip_matching=true)"
else
    echo "2. Matching features (COLMAP)..."
    if [ "$MATCHER_TYPE" = "sequential" ]; then
        echo "Using sequential matcher..."
        MATCH_CMD="colmap sequential_matcher \\
            --database_path \"$DATABASE_PATH\" \\
            --SiftMatching.gpu_index 0 \\
            --SiftMatching.use_gpu 1"
        MATCH_DESC="Feature matching (COLMAP sequential)"
    else
        echo "Using exhaustive matcher..."
        MATCH_CMD="colmap exhaustive_matcher \\
            --database_path \"$DATABASE_PATH\" \\
            --SiftMatching.gpu_index 0 \\
            --SiftMatching.use_gpu 1"
        MATCH_DESC="Feature matching (COLMAP exhaustive)"
    fi

    execute_command "$MATCH_CMD" "$MATCH_DESC"
fi

# STEP 3: Mapping/Sparse reconstruction 
if [ "$SKIP_MAPPING" = "true" ]; then
    echo "SKIPPED: Sparse reconstruction/mapping (skip_mapping=true)"
else
    # Check if we should use COLMAP mapper directly
    if [ "$USE_COLMAP_MAPPER" = "true" ]; then
        echo "3. Running sparse reconstruction (COLMAP mapper)..."
        COLMAP_CMD="colmap mapper \\
            --database_path \"$DATABASE_PATH\" \\
            --image_path \"$INPUT_PATH\" \\
            --output_path \"$SPARSE_PATH\""
        execute_command "$COLMAP_CMD" "Sparse reconstruction (COLMAP mapper)"
    else
        # Try GLOMAP first, fallback to COLMAP if needed
        GLOMAP_BIN=$(which glomap 2>/dev/null || echo "")
        GLOMAP_SUCCESSFUL=false
        
        if [ -n "$GLOMAP_BIN" ]; then
            echo "3. Running sparse reconstruction (GLOMAP)..."
            
            # Try different command patterns
            # Pattern 1: "glomap mapper" command (like COLMAP)
            GLOMAP_MAPPER_CMD="$GLOMAP_BIN mapper \\
                --database_path \"$DATABASE_PATH\" \\
                --image_path \"$INPUT_PATH\" \\
                --output_path \"$GLOMAP_PATH\""
            
            echo "Trying GLOMAP command pattern 1 (mapper)..."
            if execute_command "$GLOMAP_MAPPER_CMD" "Sparse reconstruction (GLOMAP mapper)"; then
                GLOMAP_SUCCESSFUL=true
            else
                # Pattern 2: Direct command without subcommand
                GLOMAP_DIRECT_CMD="$GLOMAP_BIN \\
                    --database_path \"$DATABASE_PATH\" \\
                    --image_path \"$INPUT_PATH\" \\
                    --output_path \"$GLOMAP_PATH\""
                
                echo "First pattern failed. Trying GLOMAP command pattern 2 (direct)..."
                if execute_command "$GLOMAP_DIRECT_CMD" "Sparse reconstruction (GLOMAP direct)"; then
                    GLOMAP_SUCCESSFUL=true
                else
                    echo "All GLOMAP command patterns failed."
                fi
            fi
            
            # Check if GLOMAP produced output
            if [ "$GLOMAP_SUCCESSFUL" = true ] && [ -d "$GLOMAP_PATH" ] && [ "$(ls -A "$GLOMAP_PATH")" ]; then
                echo "GLOMAP reconstruction successful"
                # Copy GLOMAP output to COLMAP sparse format for compatibility
                echo "4. Converting GLOMAP output to COLMAP format..."
                COPY_CMD="mkdir -p \"$SPARSE_PATH/0\" && cp -r \"$GLOMAP_PATH/\"* \"$SPARSE_PATH/0/\" 2>/dev/null || true"
                execute_command "$COPY_CMD" "Converting GLOMAP output to COLMAP format"
            else
                echo "GLOMAP reconstruction failed or produced no output. Falling back to COLMAP mapper..."
                GLOMAP_SUCCESSFUL=false
            fi
        else
            echo "GLOMAP binary not found."
        fi
        
        # If GLOMAP wasn't successful, use COLMAP mapper
        if [ "$GLOMAP_SUCCESSFUL" = false ]; then
            echo "3. Running sparse reconstruction (COLMAP fallback)..."
            COLMAP_CMD="colmap mapper \\
                --database_path \"$DATABASE_PATH\" \\
                --image_path \"$INPUT_PATH\" \\
                --output_path \"$SPARSE_PATH\""
            execute_command "$COLMAP_CMD" "Sparse reconstruction (COLMAP fallback)"
        fi
    fi
fi

echo -e "\n------------------------------------------"
echo "Sparse reconstruction process complete!"
echo "------------------------------------------"
echo "Output locations:"
if [ -d "$SPARSE_PATH" ] && [ "$(ls -A "$SPARSE_PATH")" ]; then
    echo "- COLMAP sparse reconstruction: $SPARSE_PATH"
else
    echo "- COLMAP sparse reconstruction: Not created or empty"
fi

if [ -d "$GLOMAP_PATH" ] && [ "$(ls -A "$GLOMAP_PATH")" ]; then
    echo "- GLOMAP output: $GLOMAP_PATH"
else
    echo "- GLOMAP output: Not created or empty"
fi

# Print disk usage information for the output directories
echo -e "\nOutput directory sizes:"
du -sh "$OUTPUT_PATH"/* 2>/dev/null || echo "No output directories found"

# Print database size
if [ -f "$DATABASE_PATH" ]; then
    echo -e "\nDatabase size:"
    du -sh "$DATABASE_PATH"
else
    echo -e "\nDatabase file not found"
fi

# Print command history
echo -e "\n------------------------------------------"
echo "COMMAND HISTORY SUMMARY"
echo "------------------------------------------"
for i in "${!COMMAND_HISTORY[@]}"; do
    echo "$((i+1)). ${COMMAND_HISTORY[$i]}"
    echo ""
done
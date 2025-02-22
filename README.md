# colmap_cuda_ffmpeg
## Docker container for running COLMAP using CUDA and ffmpeg


### Running it
The host machine needs to have nvidia drivers installed.

- Clone the repo
- Put your movie in the "video" directory
- Set the correct paths and set the desired FPS for frame extraction in config/colmap_config.ini
- Make sure the "images" directory is empty
- Run it as follows

```
docker run --gpus all  \
  -v "$(pwd)/video":/workspace/video  \
  -v "$(pwd)/images":/workspace/images  \
  -v "$(pwd)/output":/workspace/output   \
  -v "$(pwd)/config":/workspace/config   \
  -e CONFIG_PATH=/workspace/config/colmap_config.ini \
  thomashollier/colmap_ffmpeg
```

If you do not provide a "video" volume, the container will use any image already existing in "images" so you an curate the input images rather than extracting video frames

```
docker run --gpus all  \
  -v "$(pwd)/images":/workspace/images  \
  -v "$(pwd)/output":/workspace/output   \
  -v "$(pwd)/config":/workspace/config   \
  -e CONFIG_PATH=/workspace/config/colmap_config.ini \
  thomashollier/colmap_ffmpeg
```

### Building it

```
docker build -t [USERNAME]/colmap_ffmpeg .
```

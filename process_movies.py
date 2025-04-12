#!/usr/bin/env python3
import os
import sys
import argparse
import subprocess
import glob

def run_command(cmd, shell=True):
    """Run a command and print its output"""
    print(f"Executing: {cmd}")
    
    # Run the command and stream output in real-time
    process = subprocess.Popen(
        cmd, 
        shell=shell, 
        stdout=subprocess.PIPE, 
        stderr=subprocess.STDOUT,
        universal_newlines=True,
        bufsize=1
    )
    
    # Print output in real-time
    output = []
    for line in process.stdout:
        line = line.rstrip()
        print(line)
        output.append(line)
    
    # Wait for process to complete and get return code
    return_code = process.wait()
    if return_code != 0:
        print(f"Command failed with return code {return_code}")
    
    return '\n'.join(output)

def wslpath_w(linux_path):
    """Convert Linux path to Windows path if running on WSL"""
    return subprocess.getoutput(f'wslpath -w "{linux_path}"')

def process_movie(movie_file, config_source, do_sfm=True, do_psht=True, 
                  max_image_size=0, train_steps_limit=10, 
                  anti_aliasing=1, max_num_splats=6000, token="lores"):
    """Process a single movie file with SFM and/or Postshot"""
    # Create directory structure
    project = movie_file.replace('.mov', '')
    images_dir = os.path.join(project, "images")
    output_dir = os.path.join(project, "output")
    video_dir = os.path.join(project, "video")
    config_file = os.path.join(project, "glomap_config.ini")
    
    # Create directories if they don't exist
    for directory in [images_dir, output_dir, video_dir]:
        if not os.path.exists(directory):
            print(f"Creating directory: {directory}")
            os.makedirs(directory)
        else:
            print(f"Directory already exists: {directory}")
    
    # Run SFM reconstruction
    if do_sfm:
        # Check if the movie file is in the root directory or already in the video directory
        movie_basename = os.path.basename(movie_file)
        video_movie_path = os.path.join(video_dir, movie_basename)
        
        # Move the movie file to the video directory if it exists in the root and not in video dir
        if os.path.exists(movie_file) and not os.path.exists(video_movie_path):
            print(f"Moving {movie_file} to {video_movie_path}")
            os.rename(movie_file, video_movie_path)
        elif not os.path.exists(video_movie_path):
            print(f"Warning: Movie file {movie_basename} not found in root or video directory")
        
        # Update config file
        with open(config_source, 'r') as f:
            config_content = f.read()
        
        config_content = config_content.replace('REPLACEME', movie_basename)
        with open(config_file, 'w') as f:
            f.write(config_content)
        
        # Run Docker container - using absolute paths
        abs_images_dir = os.path.abspath(images_dir)
        abs_output_dir = os.path.abspath(output_dir)
        abs_video_dir = os.path.abspath(video_dir)
        abs_config_file = os.path.abspath(config_file)
        
        docker_cmd = f"""docker run --gpus all \\
          -v {abs_images_dir}:/workspace/images \\
          -v {abs_output_dir}:/workspace/output \\
          -v {abs_video_dir}:/workspace/video \\
          -v {abs_config_file}:/workspace/config/glomap_config.ini \\
          -e CONFIG_PATH=/workspace/config/glomap_config.ini \\
          thomashollier/glomap_recon"""
        
        run_command(docker_cmd)
    
            # Run Postshot
    if do_psht:
        # Only for Postshot: Convert paths to Windows format
        w_images = wslpath_w(images_dir)
        w_sparse = wslpath_w(os.path.join(output_dir, "sparse/0"))
        
        # Create output directory for the PSHT file if it doesn't exist
        psht_output_dir = os.path.dirname(movie_file.replace('.mov', ''))
        if not os.path.exists(psht_output_dir) and psht_output_dir:
            os.makedirs(psht_output_dir, exist_ok=True)
            
        # Get absolute path for output file
        psht_output_file = f"{movie_file.replace('.mov', '')}_{token}.psht"
        abs_psht_output_file = os.path.abspath(psht_output_file)
        w_postshot = wslpath_w(abs_psht_output_file)
        
        # Ensure output directory exists and print path information for debugging
        print(f"Postshot output file (Unix): {abs_psht_output_file}")
        print(f"Postshot output file (Windows): {w_postshot}")
        
        # Create batch file to run Postshot (Windows-specific)
        postshot_path = r"C:\Program Files\Jawset Postshot\bin\postshot-cli.exe"
        postshot_cmd = f'"{postshot_path}" train --gpu 0 --import "{w_images}" --import "{w_sparse}" --max-image-size {max_image_size} --train-steps-limit {train_steps_limit} --anti-aliasing {anti_aliasing} --max-num-splats {max_num_splats} --output "{w_postshot}"'
        
        # Write the Windows command to a batch file
        with open("runPostshot.bat", "w") as f:
            f.write(postshot_cmd)
        
        # Execute the batch file
        run_command("cmd.exe /c runPostshot.bat")
    
    print(f"Completed processing {movie_file}")

def main():
    parser = argparse.ArgumentParser(description='Process movie files for SFM reconstruction and Postshot')
    
    parser.add_argument('--movie', '-m', help='Specific movie file to process (default: all .mov files in current directory)')
    parser.add_argument('--config', '-c', help='Path to source config file', 
                      default='../bin/glomap_config.ini')
    parser.add_argument('--sfm', action='store_true', default=True, help='Run SFM reconstruction')
    parser.add_argument('--no-sfm', dest='sfm', action='store_false', help='Skip SFM reconstruction')
    parser.add_argument('--psht', action='store_true', default=True, help='Run Postshot')
    parser.add_argument('--no-psht', dest='psht', action='store_false', help='Skip Postshot')
    
    # Postshot parameters
    parser.add_argument('--max-image-size', type=int, default=0, help='Maximum image size for Postshot')
    parser.add_argument('--train-steps', type=int, default=10, help='Training steps limit for Postshot')
    parser.add_argument('--anti-aliasing', type=int, default=1, help='Anti-aliasing setting for Postshot')
    parser.add_argument('--max-splats', type=int, default=6000, help='Maximum number of splats for Postshot')
    parser.add_argument('--token', type=str, default='lores', help='Token to append to output file name')
    
    args = parser.parse_args()
    
    # Get list of movie files to process
    if args.movie:
        movie_files = [args.movie]
    else:
        movie_files = glob.glob("*.mov")
    
    if not movie_files:
        print("No movie files found to process.")
        return
    
    # Process each movie file
    for movie in movie_files:
        print(f"Processing {movie}...")
        process_movie(
            movie, 
            args.config, 
            do_sfm=args.sfm, 
            do_psht=args.psht,
            max_image_size=args.max_image_size,
            train_steps_limit=args.train_steps,
            anti_aliasing=args.anti_aliasing,
            max_num_splats=args.max_splats,
            token=args.token
        )

if __name__ == "__main__":
    main()

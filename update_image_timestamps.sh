#!/bin/bash

# =============================================================================
# Image Timestamp Updater
# =============================================================================
# 
# Description:
#   Updates image file timestamps based on metadata from various sources.
#   The script recursively processes directories and creates detailed reports.
#
# Timestamp sources (in order of priority):
#   1. Companion JSON file (looks for several field formats)
#   2. Image metadata (Create Date or Date Created fields)
#   3. Parent directory name (if last 4 characters are a valid year)
#
# Usage:
#   ./update_image_timestamps.sh <directory>         Process images in directory
#   ./update_image_timestamps.sh <dir> --test <file> Test timestamp extraction on a file
#
# Examples:
#   ./update_image_timestamps.sh /path/to/photos     Process all photos
#   ./update_image_timestamps.sh . --test image.jpg  Test on a specific file
#
# Features:
#   - Supports various media formats (images: JPG, JPEG, PNG, HEIC; videos: MP4, MOV, AVI, etc.)
#   - Handles spaces in filenames and paths
#   - Creates detailed reports for each directory
#   - Hierarchical reporting (parent directories include subdirectory counts)
#   - Test mode to verify timestamp extraction without making changes
#
# JSON file support:
#   - Looks for <filename>.json, <filename>.supplemental-metadata.json
#   - Supports Google Photos export format with nested fields
#   - Extracts from creationTime, dateCreated, createDate fields
#
# Author: Claude AI
# Date: April 25, 2025
# =============================================================================

# Show help message function
show_help() {
  echo "USAGE:"
  echo "  $0 <directory>                     Process all media files in directory"
  echo "  $0 <directory> --test <media_file> Test timestamp extraction on a specific file"
  echo "  $0 <directory> --debug             Run with debug output (saved to /tmp/timestamp_update_debug.log)"
  echo "  $0 --help                          Show this help message"
  echo ""
  echo "EXAMPLES:"
  echo "  $0 /Users/username/Pictures        Process all media files in Pictures directory"
  echo "  $0 . --test image.jpg              Test timestamp extraction on image.jpg"
  echo "  $0 /path/to/photos --debug         Process with verbose debugging information"
  echo ""
  echo "DESCRIPTION:"
  echo "  This script updates image file timestamps based on their metadata."
  echo "  It tries the following sources (in order of priority):"
  echo "    1. Companion JSON file metadata"
  echo "    2. EXIF metadata within the image file"
  echo "    3. Year extracted from parent directory name"
  echo ""
  echo "  For each directory, a results file is created with statistics."
}

# Check for help option first
if [ "$1" = "--help" ] || [ "$1" = "-h" ]; then
  show_help
  exit 0
fi

# Check if directory argument was provided
if [ $# -lt 1 ]; then
  show_help
  exit 1
fi

ROOT_DIR="$1"

# Skip directory check for help option
if [ "$2" = "--help" ] || [ "$2" = "-h" ]; then
  show_help
  exit 0
fi

# Check if the provided directory exists
if [ ! -d "$ROOT_DIR" ]; then
  echo "Error: Directory '$ROOT_DIR' does not exist."
  exit 1
fi

# Global counters
TOTAL_IMAGES=0
TOTAL_UPDATED=0

# Check for debug mode
DEBUG=0
if [ "$2" = "--debug" ] || [ "$3" = "--debug" ] || [ "$4" = "--debug" ]; then
  DEBUG=1
  echo "Running in DEBUG mode - verbose output enabled"
  exec 2>"/tmp/timestamp_update_debug.log"
  echo "Debug log started at $(date)" >&2
fi

# Function to get timestamp from companion JSON file
# Returns: formatted timestamp or empty string if not found
get_timestamp_from_json() {
  local image_file="$1"
  local json_file=""
  
  # Check different possible JSON filename patterns
  if [ -f "${image_file}.supplemental-metadata.json" ]; then
    json_file="${image_file}.supplemental-metadata.json"
  elif [ -f "${image_file%.*}.json" ]; then
    json_file="${image_file%.*}.json"
  elif [ -f "${image_file}.json" ]; then
    json_file="${image_file}.json"
  else
    return 1
  fi
  
  # First try to get photoTakenTime.timestamp from Google Photos format
  local timestamp=""
  if grep -q "photoTakenTime" "$json_file"; then
    timestamp=$(grep -A 2 '"photoTakenTime"' "$json_file" | grep 'timestamp' | sed -E 's/.*"timestamp": "([0-9]+)".*/\1/')
    
    if [ -n "$timestamp" ]; then
      # Convert Unix timestamp to formatted date
      local formatted_date=$(date -r "$timestamp" "+%Y%m%d%H%M.%S" 2>/dev/null)
      if [ -n "$formatted_date" ]; then
        echo "$formatted_date"
        return 0
      fi
    fi
  fi
  
  # Try nested creationTime.timestamp
  if grep -q "creationTime" "$json_file"; then
    timestamp=$(grep -A 2 '"creationTime"' "$json_file" | grep 'timestamp' | sed -E 's/.*"timestamp": "([0-9]+)".*/\1/')
    
    if [ -n "$timestamp" ]; then
      # Convert Unix timestamp to formatted date
      local formatted_date=$(date -r "$timestamp" "+%Y%m%d%H%M.%S" 2>/dev/null)
      if [ -n "$formatted_date" ]; then
        echo "$formatted_date"
        return 0
      fi
    fi
  fi
  
  # Try flat structure formats as before
  local json_date=""
  
  # Try direct creationTime field
  json_date=$(grep -o '"creationTime"[[:space:]]*:[[:space:]]*"[^"]*"' "$json_file" | sed 's/"creationTime"[[:space:]]*:[[:space:]]*"\([^"]*\)"/\1/')
  
  if [ -z "$json_date" ]; then
    # Try dateCreated field
    json_date=$(grep -o '"dateCreated"[[:space:]]*:[[:space:]]*"[^"]*"' "$json_file" | sed 's/"dateCreated"[[:space:]]*:[[:space:]]*"\([^"]*\)"/\1/')
  fi
  
  if [ -z "$json_date" ]; then
    # Try createDate field
    json_date=$(grep -o '"createDate"[[:space:]]*:[[:space:]]*"[^"]*"' "$json_file" | sed 's/"createDate"[[:space:]]*:[[:space:]]*"\([^"]*\)"/\1/')
  fi
  
  if [ -n "$json_date" ]; then
    # Try to handle ISO format (YYYY-MM-DDTHH:MM:SS)
    local formatted_date=$(echo "$json_date" | sed -E 's/([0-9]{4})-([0-9]{2})-([0-9]{2})T([0-9]{2}):([0-9]{2}):([0-9]{2}).*/\1\2\3\4\5.\6/')
    echo "$formatted_date"
    return 0
  fi
  
  return 1
}

# Function to get timestamp from image metadata
# Returns: formatted timestamp or empty string if not found
get_timestamp_from_metadata() {
  local image_file="$1"
  
  # Extract Create Date or Date Created from metadata
  local create_date=$(exiftool -s -s -s -CreateDate "$image_file" 2>/dev/null)
  
  # If Create Date doesn't exist, try Date Created
  if [ -z "$create_date" ]; then
    create_date=$(exiftool -s -s -s -DateCreated "$image_file" 2>/dev/null)
  fi
  
  if [ -n "$create_date" ]; then
    # Format the date for touch command (remove any fractional seconds and timezone)
    # Format: YYYY:MM:DD HH:MM:SS -> YYYYMMDDHHMM.SS
    local formatted_date=$(echo "$create_date" | sed -E 's/([0-9]{4}):([0-9]{2}):([0-9]{2}) ([0-9]{2}):([0-9]{2}):([0-9]{2}).*/\1\2\3\4\5.\6/')
    echo "$formatted_date"
    return 0
  fi
  
  return 1
}

# Function to get timestamp from parent directory name
# Returns: formatted timestamp or empty string if not found
get_timestamp_from_directory() {
  local image_file="$1"
  local parent_dir=$(dirname "$image_file")
  local dir_name=$(basename "$parent_dir")
  
  # Debug output
  if [ $DEBUG -eq 1 ]; then
    echo "  DEBUG: Checking directory: $dir_name for year in name" >&2
  fi
  
  # First try to extract the last 4 characters as a year
  local year_str=${dir_name: -4}
  
  if [ $DEBUG -eq 1 ]; then
    echo "  DEBUG: Last 4 chars: '$year_str'" >&2
  fi
  
  # Check if it's a valid 4-digit year (between 1900 and current year)
  if [[ "$year_str" =~ ^[0-9]{4}$ ]] && [ "$year_str" -ge 1900 ] && [ "$year_str" -le $(date +%Y) ]; then
    # Use January 1st of that year at 00:00:00 (in format YYYYMMDDHHMM.SS)
    local formatted_date="${year_str}0101000000.00"
    if [ $DEBUG -eq 1 ]; then
      echo "  DEBUG: Found year in directory name: $year_str, using date: $formatted_date" >&2
    fi
    echo "$formatted_date"
    return 0
  fi
  
  # If last 4 chars didn't work, try to find any 4-digit pattern that looks like a year
  local all_years=$(echo "$dir_name" | grep -o '[0-9]\{4\}')
  
  if [ -n "$all_years" ]; then
    # Check each found 4-digit number
    while read -r year_candidate; do
      if [ "$year_candidate" -ge 1900 ] && [ "$year_candidate" -le $(date +%Y) ]; then
        local formatted_date="${year_candidate}0101000000.00"
        if [ $DEBUG -eq 1 ]; then
          echo "  DEBUG: Found year in directory name: $year_candidate, using date: $formatted_date" >&2
        fi
        echo "$formatted_date"
        return 0
      fi
    done <<< "$all_years"
  fi
  
  if [ $DEBUG -eq 1 ]; then
    echo "  DEBUG: No valid year found in directory name" >&2
  fi
  return 1
}

# Function to update file timestamp
# Returns: 1 if updated, 0 if not updated
update_file_timestamp() {
  local file="$1"
  local timestamp=""
  local source=""
  
  if [ $DEBUG -eq 1 ]; then
    echo "Processing file: $(basename "$file")" >&2
  fi
  
  # Try to get timestamp from JSON first
  if [ $DEBUG -eq 1 ]; then
    echo "  Trying JSON source..." >&2
  fi
  timestamp=$(get_timestamp_from_json "$file")
  local json_result=$?
  if [ $json_result -eq 0 ]; then
    source="JSON companion file"
    if [ $DEBUG -eq 1 ]; then
      echo "  Found timestamp from JSON: $timestamp" >&2
    fi
  else
    if [ $DEBUG -eq 1 ]; then
      echo "  No JSON timestamp found, trying metadata..." >&2
    fi
    # If JSON fails, try metadata
    timestamp=$(get_timestamp_from_metadata "$file")
    local meta_result=$?
    if [ $meta_result -eq 0 ]; then
      source="image metadata"
      if [ $DEBUG -eq 1 ]; then
        echo "  Found timestamp from metadata: $timestamp" >&2
      fi
    else
      if [ $DEBUG -eq 1 ]; then
        echo "  No metadata timestamp found, trying directory name..." >&2
      fi
      # If metadata fails, try directory name
      timestamp=$(get_timestamp_from_directory "$file")
      local dir_result=$?
      if [ $dir_result -eq 0 ]; then
        source="parent directory name"
        if [ $DEBUG -eq 1 ]; then
          echo "  Found timestamp from directory name: $timestamp" >&2
        fi
      else
        if [ $DEBUG -eq 1 ]; then
          echo "  WARNING: No timestamp found from any source" >&2
        fi
      fi
    fi
  fi
  
  # If we have a timestamp, check if it's different from current and update
  if [ -n "$timestamp" ]; then
    # Get current file timestamp in seconds since epoch for comparison
    local current_timestamp=$(stat -f "%m" "$file")
    
    # Convert new timestamp to seconds since epoch for comparison
    # First create a date string that date command can parse
    local year=${timestamp:0:4}
    local month=${timestamp:4:2}
    local day=${timestamp:6:2}
    local hour=${timestamp:8:2}
    local minute=${timestamp:10:2}
    local second=${timestamp:13:2}
    if [ -z "$second" ]; then
      second="00"
    fi
    
    local date_for_compare="${year}-${month}-${day} ${hour}:${minute}:${second}"
    local new_timestamp=$(date -j -f "%Y-%m-%d %H:%M:%S" "$date_for_compare" "+%s" 2>/dev/null)
    
    # Only update if timestamps differ
    if [ -n "$new_timestamp" ] && [ "$current_timestamp" -ne "$new_timestamp" ]; then
      echo "  Updating: $(basename "$file")"
      echo "    Original timestamp: $(stat -f "%Sm" "$file")"
      echo "    New timestamp (from $source): $date_for_compare"
      
      # Ensure timestamp is properly formatted for touch command (YYYYMMDDHHMM.SS)
      # Handle potential formatting issues by verifying each component
      if [[ "$timestamp" =~ ^([0-9]{4})([0-9]{2})([0-9]{2})([0-9]{2})([0-9]{2})\.([0-9]{2})$ ]]; then
        # Timestamp is already properly formatted
        touch -t "$timestamp" "$file" 2>/dev/null || {
          echo "    WARNING: Failed to update timestamp with format $timestamp"
        }
      elif [[ "$timestamp" =~ ^([0-9]{4})([0-9]{2})([0-9]{2})([0-9]{2})([0-9]{2})([0-9]{2})$ ]]; then
        # Format with seconds but no dot
        formatted_touch_time="${timestamp:0:12}.${timestamp:12:2}"
        touch -t "$formatted_touch_time" "$file" 2>/dev/null || {
          echo "    WARNING: Failed to update timestamp with format $formatted_touch_time"
        }
      elif [[ "$timestamp" =~ ^([0-9]{4})([0-9]{2})([0-9]{2})([0-9]{2})([0-9]{2})$ ]]; then
        # Format without seconds
        touch -t "${timestamp}.00" "$file" 2>/dev/null || {
          echo "    WARNING: Failed to update timestamp with format ${timestamp}.00" 
        }
      else
        echo "    WARNING: Invalid timestamp format: $timestamp, skipping update"
        return 0
      fi
      return 1
    else
      echo "  Skipping (timestamp already matches): $(basename "$file")"
      return 0
    fi
  else
    echo "  Skipping (no timestamp found): $(basename "$file")"
    return 0
  fi
}

# Function to read subdirectory counts from result files
read_subdirectory_counts() {
  local dir="$1"
  local total_img_count=0
  local total_upd_count=0
  
  # Find all subdirectories
  while IFS= read -r -d $'\0' subdir; do
    local sub_result_file="${subdir}/image_timestamp_results.txt"
    
    if [ -f "$sub_result_file" ]; then
      # Extract total media files count
      local img_count=$(grep "Total media files (including subdirectories):" "$sub_result_file" | sed 's/.*: //')
      # Extract total updated count
      local upd_count=$(grep "Total media files updated (including subdirectories):" "$sub_result_file" | sed 's/.*: //')
      
      if [ $DEBUG -eq 1 ]; then
        echo "DEBUG: From $subdir result file, found counts: $img_count, $upd_count" >&2
      fi
      
      # Add to totals if they're valid numbers
      if [[ "$img_count" =~ ^[0-9]+$ ]]; then
        total_img_count=$((total_img_count + img_count))
      fi
      
      if [[ "$upd_count" =~ ^[0-9]+$ ]]; then
        total_upd_count=$((total_upd_count + upd_count))
      fi
    fi
  done < <(find "$dir" -maxdepth 1 -type d -not -path "$dir" -not -path "*/\.*" -print0)
  
  # Return the counts
  echo "$total_img_count $total_upd_count"
}

# Function to process a directory
process_directory() {
  local dir="$1"
  local result_file="${dir}/image_timestamp_results.txt"
  
  echo "Processing directory: $dir"
  
  # First process all subdirectories before processing files in this directory
  # This ensures we have the subdirectory results files available
  local subdirectories=()
  
  # Get list of subdirectories
  while IFS= read -r -d $'\0' subdir; do
    subdirectories+=("$subdir")
  done < <(find "$dir" -maxdepth 1 -type d -not -path "$dir" -not -path "*/\.*" -print0)
  
  # Process each subdirectory first
  for subdir in "${subdirectories[@]}"; do
    process_directory "$subdir"
  done
  
  # Now process files in this directory
  local dir_image_count=0
  local dir_updated_count=0
  
  # Process media files in the current directory
  while IFS= read -r -d $'\0' file; do
    # Skip non-media files (images and videos)
    if [[ ! "$file" =~ \.(jpg|jpeg|png|heic|HEIC|JPG|JPEG|PNG|mp4|MP4|mov|MOV|avi|AVI|m4v|M4V|mkv|MKV|3gp|3GP|wmv|WMV)$ ]]; then
      continue
    fi
    
    # Increment media file counter
    ((dir_image_count++))
    
    # Update file timestamp and get result
    if update_file_timestamp "$file"; then
      # No update performed
      :
    else
      # File was updated
      ((dir_updated_count++))
    fi
  done < <(find "$dir" -maxdepth 1 -type f -not -path "*/\.*" -print0)
  
  # Read subdirectory counts from their result files
  local subdir_counts=$(read_subdirectory_counts "$dir")
  local subdir_image_count=$(echo $subdir_counts | cut -d' ' -f1)
  local subdir_updated_count=$(echo $subdir_counts | cut -d' ' -f2)
  
  if [ $DEBUG -eq 1 ]; then
    echo "DEBUG: $dir has direct counts: $dir_image_count, $dir_updated_count" >&2
    echo "DEBUG: $dir has subdir counts: $subdir_image_count, $subdir_updated_count" >&2
  fi
  
  # Total counts (direct + subdirectory)
  local total_image_count=$((dir_image_count + subdir_image_count))
  local total_updated_count=$((dir_updated_count + subdir_updated_count))
  
  # Check if result file already exists and remove it
  if [ -f "$result_file" ]; then
    rm "$result_file"
  fi
  
  # Create result file
  echo "Image Timestamp Update Results - $(date)" > "$result_file"
  echo "Directory: $dir" >> "$result_file"
  echo "=====================================" >> "$result_file"
  echo "" >> "$result_file"
  echo "Summary:" >> "$result_file"
  echo "  Direct media files in this directory: $dir_image_count" >> "$result_file"
  echo "  Direct media files updated in this directory: $dir_updated_count" >> "$result_file"
  
  if [ $subdir_image_count -gt 0 ]; then
    echo "  Media files in subdirectories: $subdir_image_count" >> "$result_file"
    echo "  Media files updated in subdirectories: $subdir_updated_count" >> "$result_file"
  fi
  
  echo "  Total media files (including subdirectories): $total_image_count" >> "$result_file"
  echo "  Total media files updated (including subdirectories): $total_updated_count" >> "$result_file"
  echo "Completed at: $(date)" >> "$result_file"
  
  # Update global counters for the root call
  if [ "$dir" = "$ROOT_DIR" ]; then
    TOTAL_IMAGES=$total_image_count
    TOTAL_UPDATED=$total_updated_count
  fi
  
  # Display directory summary
  echo "Directory Summary for: $dir"
  echo "  Direct media files in this directory: $dir_image_count"
  echo "  Direct media files updated in this directory: $dir_updated_count"
  
  if [ $subdir_image_count -gt 0 ]; then
    echo "  Media files in subdirectories: $subdir_image_count"
    echo "  Media files updated in subdirectories: $subdir_updated_count"
  fi
  
  echo "  Total media files (including subdirectories): $total_image_count"
  echo "  Total media files updated (including subdirectories): $total_updated_count"
  echo ""
}

# Function to test the timestamp extraction functions
test_timestamp_functions() {
  local test_file="$1"
  
  echo "Testing timestamp extraction functions on: $test_file"
  echo "=================================================="
  
  # Show current file timestamp for comparison
  echo "Current file timestamp: $(stat -f "%Sm" "$test_file")"
  
  # Test JSON extraction
  local json_timestamp=""
  json_timestamp=$(get_timestamp_from_json "$test_file")
  local json_result=$?
  if [ $json_result -eq 0 ]; then
    echo "JSON Timestamp: $json_timestamp (Success)"
    
    # Format for display
    local year=${json_timestamp:0:4}
    local month=${json_timestamp:4:2}
    local day=${json_timestamp:6:2}
    local hour=${json_timestamp:8:2}
    local minute=${json_timestamp:10:2}
    local second=${json_timestamp:13:2}
    if [ -z "$second" ]; then
      second="00"
    fi
    echo "  Human readable: ${year}-${month}-${day} ${hour}:${minute}:${second}"
  else
    echo "JSON Timestamp: Not found"
  fi
  
  # Test metadata extraction
  local meta_timestamp=""
  meta_timestamp=$(get_timestamp_from_metadata "$test_file")
  local meta_result=$?
  if [ $meta_result -eq 0 ]; then
    echo "Metadata Timestamp: $meta_timestamp (Success)"
    
    # Format for display
    local year=${meta_timestamp:0:4}
    local month=${meta_timestamp:4:2}
    local day=${meta_timestamp:6:2}
    local hour=${meta_timestamp:8:2}
    local minute=${meta_timestamp:10:2}
    local second=${meta_timestamp:13:2}
    if [ -z "$second" ]; then
      second="00"
    fi
    echo "  Human readable: ${year}-${month}-${day} ${hour}:${minute}:${second}"
  else
    echo "Metadata Timestamp: Not found"
  fi
  
  # Test directory name extraction
  local dir_timestamp=""
  dir_timestamp=$(get_timestamp_from_directory "$test_file")
  local dir_result=$?
  if [ $dir_result -eq 0 ]; then
    echo "Directory Timestamp: $dir_timestamp (Success)"
    
    # Format for display
    local year=${dir_timestamp:0:4}
    local month=${dir_timestamp:4:2}
    local day=${dir_timestamp:6:2}
    local hour=${dir_timestamp:8:2}
    local minute=${dir_timestamp:10:2}
    local second=${dir_timestamp:13:2}
    if [ -z "$second" ]; then
      second="00"
    fi
    echo "  Human readable: ${year}-${month}-${day} ${hour}:${minute}:${second}"
  else
    echo "Directory Timestamp: Not found"
  fi
  
  echo "--------------------------------------------------"
  echo "Final timestamp that would be used:"
  
  # Determine which timestamp would be used (using same priority logic)
  if [ $json_result -eq 0 ] && [ -n "$json_timestamp" ]; then
    echo "Source: JSON companion file"
    echo "Value: $json_timestamp"
    
    # Format for display
    local year=${json_timestamp:0:4}
    local month=${json_timestamp:4:2}
    local day=${json_timestamp:6:2}
    local hour=${json_timestamp:8:2}
    local minute=${json_timestamp:10:2}
    local second=${json_timestamp:13:2}
    if [ -z "$second" ]; then
      second="00"
    fi
    echo "Human readable: ${year}-${month}-${day} ${hour}:${minute}:${second}"
  elif [ $meta_result -eq 0 ] && [ -n "$meta_timestamp" ]; then
    echo "Source: Image metadata"
    echo "Value: $meta_timestamp"
    
    # Format for display
    local year=${meta_timestamp:0:4}
    local month=${meta_timestamp:4:2}
    local day=${meta_timestamp:6:2}
    local hour=${meta_timestamp:8:2}
    local minute=${meta_timestamp:10:2}
    local second=${meta_timestamp:13:2}
    if [ -z "$second" ]; then
      second="00"
    fi
    echo "Human readable: ${year}-${month}-${day} ${hour}:${minute}:${second}"
  elif [ $dir_result -eq 0 ] && [ -n "$dir_timestamp" ]; then
    echo "Source: Parent directory name"
    echo "Value: $dir_timestamp"
    
    # Format for display
    local year=${dir_timestamp:0:4}
    local month=${dir_timestamp:4:2}
    local day=${dir_timestamp:6:2}
    local hour=${dir_timestamp:8:2}
    local minute=${dir_timestamp:10:2}
    local second=${dir_timestamp:13:2}
    if [ -z "$second" ]; then
      second="00"
    fi
    echo "Human readable: ${year}-${month}-${day} ${hour}:${minute}:${second}"
  else
    echo "No valid timestamp found"
  fi
  
  echo "=================================================="
}

# Main execution logic
if [ "$2" = "--test" ] && [ -n "$3" ]; then
  # Run in test mode for a specific file
  echo "Running in TEST MODE"
  echo "No files will be modified"
  echo ""
  test_timestamp_functions "$3"
  
  # Also try the parent directory name extraction directly for verification
  echo ""
  echo "EXTRA DIRECTORY NAME VERIFICATION:"
  parent_dir=$(dirname "$3")
  dir_name=$(basename "$parent_dir")
  echo "Parent directory: $dir_name"
  
  # Extract all 4-digit numbers that could be years
  echo "Checking for 4-digit years in directory name:"
  all_years=$(echo "$dir_name" | grep -o '[0-9]\{4\}')
  if [ -n "$all_years" ]; then
    echo "Found potential years: $all_years"
    while read -r year_candidate; do
      if [ "$year_candidate" -ge 1900 ] && [ "$year_candidate" -le $(date +%Y) ]; then
        echo "  Valid year found: $year_candidate (will be used if no other timestamp source is available)"
      else
        echo "  Invalid year found: $year_candidate (out of valid range 1900-$(date +%Y))"
      fi
    done <<< "$all_years"
  else
    echo "No 4-digit numbers found in directory name"
  fi
  
  echo ""
  echo "To update this file, run without the --test option:"
  echo "$0 $(dirname "$3")"
  
elif [ "$2" = "--help" ] || [ "$2" = "-h" ]; then
  # Show help text
  show_help
  
else
  # Normal processing mode
  echo "Starting to process media files in $ROOT_DIR and subdirectories..."
  echo ""
  
  # Process the root directory and all subdirectories
  process_directory "$ROOT_DIR"
  
  # Display overall summary
  echo "Overall Summary:"
  echo "  Total media files processed: $TOTAL_IMAGES"
  echo "  Total media files updated: $TOTAL_UPDATED"
  echo ""
  
  echo "Done processing all media files."
  echo "Result file created: $ROOT_DIR/image_timestamp_results.txt"
fi
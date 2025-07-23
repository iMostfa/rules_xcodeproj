#!/bin/bash
set -euo pipefail

# Define constants within the script
TOOLCHAIN_NAME_BASE="%toolchain_name_base%"
TOOLCHAIN_DIR="%toolchain_dir%"
XCODE_VERSION="%xcode_version%"

# Function to retry commands with exponential backoff
retry_command() {
    local max_attempts=3
    local delay=1
    local attempt=1
    
    while [ $attempt -le $max_attempts ]; do
        if "$@"; then
            return 0
        fi
        
        if [ $attempt -lt $max_attempts ]; then
            echo "Command failed (attempt $attempt/$max_attempts), retrying in ${delay}s..." >&2
            sleep $delay
            delay=$((delay * 2))
        fi
        attempt=$((attempt + 1))
    done
    
    echo "Command failed after $max_attempts attempts: $*" >&2
    return 1
}

# Clean up temp files on exit
TOOL_NAMES_FILE=$(mktemp)
trap 'rm -f "$TOOL_NAMES_FILE"' EXIT

echo "%tool_names_list%" > "$TOOL_NAMES_FILE"

# Get Xcode version and default toolchain path with retry logic
DEFAULT_TOOLCHAIN=$(retry_command xcrun --find clang | sed 's|/usr/bin/clang$||')
XCODE_RAW_VERSION=$(retry_command xcodebuild -version | head -n 1)

HOME_TOOLCHAIN_NAME="BazelRulesXcodeProj${XCODE_VERSION}"
USER_TOOLCHAIN_PATH="/Users/$(id -un)/Library/Developer/Toolchains/${HOME_TOOLCHAIN_NAME}.xctoolchain"
BUILT_TOOLCHAIN_PATH="$PWD/$TOOLCHAIN_DIR"

retry_command mkdir -p "$TOOLCHAIN_DIR"

# Process all files from the default toolchain using process substitution to avoid broken pipes
echo "Processing toolchain files from $DEFAULT_TOOLCHAIN..." >&2
while read -r file; do
    # Skip empty lines
    [[ -n "$file" ]] || continue
    
    rel_path="${file#"$DEFAULT_TOOLCHAIN/"}"
    base_name=$(basename "$rel_path")

    # Skip ToolchainInfo.plist as we'll create our own
    if [[ "$rel_path" == "ToolchainInfo.plist" ]]; then
        continue
    fi

    # Check if this file is in the list of tools to be overridden
    should_skip=0
    for tool_name in $(cat "$TOOL_NAMES_FILE"); do
        if [[ "$base_name" == "$tool_name" ]]; then
            # Skip creating a symlink for overridden tools
            should_skip=1
            break
        fi
    done

    if [[ $should_skip -eq 1 ]]; then
        continue
    fi

    # Ensure parent directory exists with retry logic
    target_dir="$TOOLCHAIN_DIR/$(dirname "$rel_path")"
    retry_command mkdir -p "$target_dir"

    # Create symlink to the original file with retry logic
    target_path="$TOOLCHAIN_DIR/$rel_path"
    retry_command ln -sf "$file" "$target_path"
    
    # Verify symlink was created successfully
    if [[ ! -e "$target_path" && ! -L "$target_path" ]]; then
        echo "Warning: Failed to create symlink $target_path" >&2
    fi
done < <(find "$DEFAULT_TOOLCHAIN" -type f -o -type l 2>/dev/null || {
    echo "Error: Failed to find files in $DEFAULT_TOOLCHAIN" >&2
    exit 1
})

# Generate the ToolchainInfo.plist directly with Xcode version information
cat > "$TOOLCHAIN_DIR/ToolchainInfo.plist" << EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple Computer//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
  <dict>
    <key>Aliases</key>
    <array>
      <string>${HOME_TOOLCHAIN_NAME}</string>
    </array>
    <key>CFBundleIdentifier</key>
    <string>com.rules_xcodeproj.BazelRulesXcodeProj.${XCODE_VERSION}</string>
    <key>CompatibilityVersion</key>
    <integer>2</integer>
    <key>CompatibilityVersionDisplayString</key>
    <string>${XCODE_RAW_VERSION}</string>
    <key>DisplayName</key>
    <string>${HOME_TOOLCHAIN_NAME}</string>
    <key>ReportProblemURL</key>
    <string>https://github.com/MobileNativeFoundation/rules_xcodeproj</string>
    <key>ShortDisplayName</key>
    <string>${HOME_TOOLCHAIN_NAME}</string>
    <key>Version</key>
    <string>0.1.0</string>
  </dict>
</plist>
EOF

# Note: We intentionally do NOT create .dia files here
# Missing .dia files are better than invalid ASCII text ones that cause
# "Invalid diagnostics signature" errors in Xcode Previews
# However, we need to include the specific binary cc.dia file that clang.sh expects
TOOLCHAIN_BIN_DIR="$TOOLCHAIN_DIR/usr/bin"
mkdir -p "$TOOLCHAIN_BIN_DIR"

# Copy the binary cc.dia file that clang.sh needs
# This is a proper binary diagnostic file, not an ASCII placeholder
# Find cc.dia in the current directory and its subdirectories (from Bazel inputs)
echo "Looking for cc.dia file..." >&2
CC_DIA_FILE=$(find . -name "cc.dia" -type f 2>/dev/null | head -1)
if [[ -f "$CC_DIA_FILE" ]]; then
    retry_command cp "$CC_DIA_FILE" "$TOOLCHAIN_BIN_DIR/cc.dia"
    echo "Copied cc.dia from $CC_DIA_FILE to $TOOLCHAIN_BIN_DIR/cc.dia" >&2
    
    # Verify the file was copied successfully
    if [[ ! -f "$TOOLCHAIN_BIN_DIR/cc.dia" ]]; then
        echo "Error: Failed to copy cc.dia file" >&2
        exit 1
    fi
else
    echo "Warning: cc.dia file not found in inputs" >&2
fi

# Create user toolchain symlink with retry logic
user_toolchain_dir="$(dirname "$USER_TOOLCHAIN_PATH")"
retry_command mkdir -p "$user_toolchain_dir"

if [[ -e "$USER_TOOLCHAIN_PATH" || -L "$USER_TOOLCHAIN_PATH" ]]; then
    retry_command rm -rf "$USER_TOOLCHAIN_PATH"
fi

retry_command ln -sf "$BUILT_TOOLCHAIN_PATH" "$USER_TOOLCHAIN_PATH"

# Verify final symlink was created successfully
if [[ ! -L "$USER_TOOLCHAIN_PATH" ]]; then
    echo "Error: Failed to create user toolchain symlink at $USER_TOOLCHAIN_PATH" >&2
    exit 1
fi

echo "Successfully created custom toolchain at $USER_TOOLCHAIN_PATH" >&2

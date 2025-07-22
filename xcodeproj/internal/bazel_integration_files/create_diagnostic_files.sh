#!/bin/bash

set -euo pipefail

# Create placeholder diagnostic files for compilation units that lack them
# This prevents Xcode from showing warnings about missing .dia files

readonly target_name="${1:-unknown}"
readonly object_file_dir="${OBJECT_FILE_DIR_normal}/arm64"

if [[ "${ENABLE_PREVIEWS:-}" == "YES" && -d "$object_file_dir" ]]; then
  echo "Cleaning up problematic diagnostic files for preview build..." >&2
  
  # Remove any ASCII text .dia files that cause "Invalid diagnostics signature" errors
  # These are our old placeholder files that Xcode can't read properly
  find "$object_file_dir" -name '*.dia' -type f 2>/dev/null | while read -r dia_file; do
    if file "$dia_file" | grep -q "ASCII text"; then
      echo "Removing problematic text diagnostic file: $dia_file" >&2
      rm -f "$dia_file" 2>/dev/null || {
        # If we can't remove it due to permissions, try to fix permissions first
        chmod 644 "$dia_file" 2>/dev/null
        xattr -c "$dia_file" 2>/dev/null  # Remove extended attributes
        rm -f "$dia_file" 2>/dev/null || echo "Warning: Could not remove $dia_file" >&2
      }
    fi
  done
  
  # Do NOT create new .dia files - let Bazel handle them properly
  # Missing .dia files are better than invalid ones for Xcode Preview builds
  
  # Also clean up toolchain diagnostic files
  readonly toolchain_dir="/Users/$(whoami)/Library/Developer/Toolchains/BazelRulesXcodeProj16F6.xctoolchain/usr/bin"
  
  if [[ -d "$toolchain_dir" ]]; then
    # Remove any problematic text diagnostic files from toolchain
    for tool_file in cc.dia clang.dia swift.dia clang++.dia swiftc.dia; do
      tool_path="$toolchain_dir/$tool_file"
      if [[ -f "$tool_path" ]] && file "$tool_path" | grep -q "ASCII text"; then
        echo "Removing problematic toolchain diagnostic file: $tool_path" >&2
        rm -f "$tool_path" 2>/dev/null || echo "Warning: Could not remove $tool_path" >&2
      fi
    done
  fi
  
  echo "Diagnostic files setup complete for preview build" >&2
fi 
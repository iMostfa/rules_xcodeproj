#!/bin/bash

set -euo pipefail

# Create placeholder diagnostic files for compilation units that lack them
# This prevents Xcode from showing warnings about missing .dia files

readonly target_name="${1:-unknown}"
readonly object_file_dir="${OBJECT_FILE_DIR_normal}/arm64"

if [[ "${ENABLE_PREVIEWS:-}" == "YES" && -d "$object_file_dir" ]]; then
  echo "Cleaning up problematic files for preview build..." >&2
  
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
  
  # Fix permissions on read-only Swift build artifacts that Xcode Preview needs to overwrite
  # Look in the Bazel output directory for Swift header files and modules
  readonly bazel_output_dir="/var/tmp/_bazel_$(whoami)/*/rules_xcodeproj.noindex/build_output_base/execroot/_main/bazel-out"
  
  # Find all Swift header files and make them writable
  find $bazel_output_dir -name "*-Swift.h" -type f 2>/dev/null | while read -r swift_header; do
    if [[ ! -w "$swift_header" ]]; then
      echo "Making Swift header writable: $swift_header" >&2
      chmod 644 "$swift_header" 2>/dev/null || echo "Warning: Could not modify permissions for $swift_header" >&2
      xattr -c "$swift_header" 2>/dev/null || true  # Remove extended attributes that might block writes
    fi
  done
  
  # Find Swift module files and make them writable
  find $bazel_output_dir -name "*.swiftmodule" -o -name "*.swiftdoc" -o -name "*.abi.json" 2>/dev/null | while read -r swift_file; do
    if [[ ! -w "$swift_file" ]]; then
      echo "Making Swift artifact writable: $swift_file" >&2
      chmod 644 "$swift_file" 2>/dev/null || echo "Warning: Could not modify permissions for $swift_file" >&2
      xattr -c "$swift_file" 2>/dev/null || true
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
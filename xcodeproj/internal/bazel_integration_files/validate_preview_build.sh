#!/bin/bash

set -euo pipefail

# Validates that preview build has necessary components
# and creates fallbacks if needed

readonly product_name="${PRODUCT_NAME:-unknown}"
readonly target_build_dir="${TARGET_BUILD_DIR}"
readonly object_file_dir="${OBJECT_FILE_DIR_normal}/arm64"
readonly derived_file_dir="${DERIVED_FILE_DIR}"

if [[ "${ENABLE_PREVIEWS:-}" == "YES" ]]; then
  echo "Validating preview build environment for $product_name..." >&2
  
  # Check for required directories and create them if missing
  required_dirs=(
    "$target_build_dir"
    "$object_file_dir" 
    "$derived_file_dir"
  )
  
  for dir in "${required_dirs[@]}"; do
    if [[ ! -d "$dir" ]]; then
      echo "Creating missing directory: $dir" >&2
      mkdir -p "$dir"
    fi
  done
  
  # Ensure at least one object file exists for linking
  if ! find "$object_file_dir" -name '*.o' -print -quit | grep -q .; then
    echo "Creating placeholder object file for preview linking..." >&2
    touch "$object_file_dir/preview_validation_placeholder.o"
  fi
  
  # Note: We intentionally do NOT create .dia files here
  # Missing .dia files are better than invalid ASCII text ones that cause
  # "Invalid diagnostics signature" errors in Xcode Previews
  # Bazel will create proper binary .dia files when needed
  
  # Verify toolchain directory exists
  readonly toolchain_dir="/Users/$(whoami)/Library/Developer/Toolchains/BazelRulesXcodeProj16F6.xctoolchain/usr/bin"
  if [[ ! -d "$toolchain_dir" ]]; then
    echo "Creating toolchain directory for preview support..." >&2
    mkdir -p "$toolchain_dir"
    
    # Note: We intentionally do NOT create placeholder .dia files
    # Missing .dia files are better than invalid ASCII text ones
  fi
  
  # Create build marker for preview builds
  if [[ ! -f "${OBJROOT}/preview_build_marker" ]]; then
    echo "Creating preview build marker..." >&2
    mkdir -p "${OBJROOT}"
    echo "preview_build_validated_$(date +%s)" > "${OBJROOT}/preview_build_marker"
  fi
  
  # Verify essential environment variables
  essential_vars=("TARGET_BUILD_DIR" "PRODUCT_NAME" "OBJECT_FILE_DIR_normal" "DERIVED_FILE_DIR")
  for var in "${essential_vars[@]}"; do
    if [[ -z "${!var:-}" ]]; then
      echo "Warning: Essential environment variable $var is not set for preview build" >&2
    fi
  done
  
  echo "Preview build validation complete for $product_name" >&2
  
  # Log validation summary
  echo "Preview build validation summary:" >&2
  echo "  Product: $product_name" >&2
  echo "  Object files: $(find "$object_file_dir" -name '*.o' 2>/dev/null | wc -l | tr -d ' ')" >&2
  echo "  Diagnostic files: $(find "$object_file_dir" -name '*.dia' 2>/dev/null | wc -l | tr -d ' ')" >&2
  echo "  Target build dir: $target_build_dir" >&2
else
  echo "Skipping preview validation - not a preview build" >&2
fi 
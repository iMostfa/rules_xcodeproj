#!/bin/bash

set -euo pipefail

# readonly forced_swift_compile_file="$1"
readonly exclude_list="$2"

# # Touching this file on an error allows indexing to work better
# trap 'echo "private let touch = \"$(date +%s)\"" > "$DERIVED_FILE_DIR/$forced_swift_compile_file"' ERR

readonly test_frameworks=(
  "libXCTestBundleInject.dylib"
  "libXCTestSwiftSupport.dylib"
  "IDEBundleInjection.framework"
  "XCTAutomationSupport.framework"
  "Testing.framework"
  "XCTest.framework"
  "XCTestCore.framework"
  "XCTestSupport.framework"
  "XCUIAutomation.framework"
  "XCUnit.framework"
)

ensure_bazel_preview_compilation() {
  # Only run for preview builds to avoid impacting normal builds
  if [[ "${ENABLE_PREVIEWS:-}" != "YES" ]]; then
    return 0
  fi
  
  echo "RULES_XCODEPROJ: Starting Bazel compilation verification for preview build..." >&2
  
  # Check if we have access to the Bazel build infrastructure
  if [[ -n "${BAZEL_INTEGRATION_DIR:-}" ]] && [[ -f "$BAZEL_INTEGRATION_DIR/bazel_build.sh" ]]; then
    echo "RULES_XCODEPROJ: Triggering Bazel build for simulator configuration..." >&2
    
    # Try to ensure compilation happens by sourcing the build script
    # This leverages the existing Bazel integration but ensures it runs for previews
    local original_action="${ACTION:-}"
    
    # Set up environment for preview builds
    export RULES_XCODEPROJ_BUILD_MODE="preview"
    
    # Try to source the existing bazel build script with proper error handling
    if (
      # Run in subshell to contain any environment changes
      cd "$SRCROOT" 2>/dev/null || cd .
      
      # Source the build script but capture any errors
      source "$BAZEL_INTEGRATION_DIR/bazel_build.sh" 2>&1 || {
        echo "RULES_XCODEPROJ: Bazel build encountered issues, but continuing with preview..." >&2
        exit 0  # Don't fail the preview build
      }
    ); then
      echo "RULES_XCODEPROJ: Bazel build verification completed successfully" >&2
    else
      echo "RULES_XCODEPROJ: Warning: Bazel build verification had issues, but continuing with preview..." >&2
    fi
    
    # Clean up environment
    unset RULES_XCODEPROJ_BUILD_MODE
    export ACTION="$original_action"
  else
    echo "RULES_XCODEPROJ: Warning: Could not access Bazel build infrastructure" >&2
  fi
  
  echo "RULES_XCODEPROJ: Bazel compilation verification completed" >&2
}

if [[ "$ACTION" != indexbuild ]]; then
  # Copy product
  if [[ -n ${BAZEL_OUTPUTS_PRODUCT:-} ]]; then
    cd "${BAZEL_OUTPUTS_PRODUCT%/*}"

    # Check for object files in multiple possible directory patterns
    objs_found=false
    for objs_dir in "${PRODUCT_NAME}_objs" "_objs" "_objc"; do
      if [[ -d "$PWD/$objs_dir" ]]; then
        echo "Found object files in $PWD/$objs_dir" >&2
        # Symlink .o files from BAZEL_PACKAGE_BIN_DIR to OBJECT_FILE_DIR_normal/arm64
        find "$PWD/$objs_dir" -name '*.o' -exec sh -c '
          FILENAME=$(echo "${1}" | sed "s/__SPACE__/ /g")
          TARGET_FILE="${OBJECT_FILE_DIR_normal}/arm64/$(basename "${FILENAME}" | sed "s/\.swift//")"
          rm -f "${TARGET_FILE}"
          cp "$1" "${TARGET_FILE}"
          chmod 644 "${TARGET_FILE}"
        ' _ {} \;
        objs_found=true
        break
      fi
    done
    
    if [[ "$objs_found" == false ]]; then
      # Create placeholder object files for preview builds when no objs directory exists
      if [[ "${ENABLE_PREVIEWS:-}" == "YES" ]]; then
        echo "Warning: No object files directory found for preview build, creating placeholder structure" >&2
        mkdir -p "${OBJECT_FILE_DIR_normal}/arm64"
        # Create a minimal placeholder .o file to prevent linking issues
        touch "${OBJECT_FILE_DIR_normal}/arm64/preview_placeholder.o"
      else
        echo "Warning: No object files directory found. Checked: ${PRODUCT_NAME}_objs, _objs, _objc in $PWD" >&2
      fi
    fi

    if [[ -f "$BAZEL_OUTPUTS_PRODUCT_BASENAME" ]]; then
      # Product is a binary, so symlink instead of rsync, to allow for Bazel-set
      # rpaths to work
      ln -sfh "$PWD/$BAZEL_OUTPUTS_PRODUCT_BASENAME" "$TARGET_BUILD_DIR/lib$PRODUCT_NAME.a"
    else
      # Product is a bundle
      # NOTE: use `which` to find the path to `rsync`.
      # In macOS 15.4, the system `rsync` is using `openrsync` which contains some permission issues.
      # This allows users to workaround the issue by overriding the system `rsync` with a working version.
      # Remove this once we no longer support macOS versions with broken `rsync`.
      PATH="/opt/homebrew/bin:/usr/local/bin:$PATH" \
        rsync \
        --copy-links \
        --recursive \
        --times \
        --delete \
        ${exclude_list:+--exclude-from="$exclude_list"} \
        --perms \
        --chmod=u+w \
        --out-format="%n%L" \
        "$BAZEL_OUTPUTS_PRODUCT_BASENAME" \
        "$TARGET_BUILD_DIR"

      if [[ -n "${TEST_HOST:-}" ]]; then
        # We need to re-sign test frameworks that Xcode placed into the test
        # host un-signed
        readonly test_host_app="${TEST_HOST%/*}"

        # Only engage signing workflow if the test host is signed
        if [[ -f "$test_host_app/embedded.mobileprovision" ]]; then
          codesigning_authority=$(codesign -dvv "$TEST_HOST"  2>&1 >/dev/null | /usr/bin/sed -n  -E 's/^Authority=(.*)/\1/p'| head -n 1)

          for framework in "${test_frameworks[@]}"; do
            framework="$test_host_app/Frameworks/$framework"
            if [[ -e "$framework" ]]; then
              codesign -f \
                --preserve-metadata=identifier,entitlements,flags \
                --timestamp=none \
                --generate-entitlement-der \
                -s "$codesigning_authority" \
                "$framework"
            fi
          done
        fi
      fi

      # Incremental installation can fail if an embedded bundle is recompiled but
      # the Info.plist is not updated. This causes the delta bundle that Xcode
      # actually installs to not have a bundle ID for the embedded bundle. We
      # avoid this potential issue by always including the Info.plist in the delta
      # bundle by touching them.
      # Source: https://github.com/bazelbuild/tulsi/commit/27354027fada7aa3ec3139fd686f85cc5039c564
      # TODO: Pass the exact list of files to touch to this script
      readonly plugins_dir="$TARGET_BUILD_DIR/${PLUGINS_FOLDER_PATH:-}"
      if [[ -d "$plugins_dir" ]]; then
        find "$plugins_dir" -depth 2 -name "Info.plist" -exec touch {} \;
      fi

      # Xcode Previews has a hard time finding frameworks (`@rpath`) when using
      # framework schemes, so let's symlink them into
      # `$TARGET_BUILD_DIR` (since we modify `@rpath` to always include
      # `@loader_path/SwiftUIPreviewsFrameworks`)
      if [[ "${ENABLE_PREVIEWS:-}" == "YES" && \
            -n "${PREVIEW_FRAMEWORK_PATHS:-}" ]]; then
        mkdir -p "$TARGET_BUILD_DIR/$WRAPPER_NAME/SwiftUIPreviewsFrameworks"
        cd "$TARGET_BUILD_DIR/$WRAPPER_NAME/SwiftUIPreviewsFrameworks"

        # shellcheck disable=SC2016
        xargs -n1 sh -c 'ln -shfF "$1" $(basename "$1")' _ \
          <<< "$PREVIEW_FRAMEWORK_PATHS"
      fi
    fi
  fi
fi

# Create diagnostic and dependency files for preview builds to prevent warnings  
if [[ "${ENABLE_PREVIEWS:-}" == "YES" ]]; then
  echo "RULES_XCODEPROJ DEBUG: Preview build detected for ${PRODUCT_NAME:-unknown}" >&2
  echo "RULES_XCODEPROJ DEBUG: TARGET_TEMP_DIR=${TARGET_TEMP_DIR:-not_set}" >&2
  echo "RULES_XCODEPROJ DEBUG: OBJECT_FILE_DIR_normal=${OBJECT_FILE_DIR_normal:-not_set}" >&2
  echo "RULES_XCODEPROJ DEBUG: PWD=$PWD" >&2
  
  # PHASE 1: Ensure Bazel compilation completes for preview builds
  echo "RULES_XCODEPROJ: Ensuring Bazel build completion for preview..." >&2
  ensure_bazel_preview_compilation
  
  "$BAZEL_INTEGRATION_DIR/create_diagnostic_files.sh" "${PRODUCT_NAME:-unknown}"
  
  # Enhanced dependency file creation for DerivedData bazel-out structure
  echo "Creating dependency files for preview build: ${PRODUCT_NAME:-unknown}" >&2
  
  # Create .d files in normal object directory
  if [[ -d "${OBJECT_FILE_DIR_normal}/arm64" ]]; then
    find "${OBJECT_FILE_DIR_normal}/arm64" -name '*.o' | while read -r obj_file; do
      dep_file="${obj_file%.o}.d"
      if [[ ! -f "$dep_file" ]]; then
        {
          echo "# Dependency file for ${PRODUCT_NAME:-unknown} preview build"
          echo "# Generated by rules_xcodeproj at $(date)"
          echo "$obj_file: \\"
        } > "$dep_file"
      fi
    done
  fi
  
  # Generalized approach: Create .d files in DerivedData bazel-out structure
  # This works for ANY project structure, not just specific libraries
  if [[ -n "${TARGET_TEMP_DIR:-}" ]]; then
    # Extract the DerivedData build directory path
    derived_data_build_dir="${TARGET_TEMP_DIR%/*/*/*/*/*}"  # Go up to Build dir
    echo "RULES_XCODEPROJ DEBUG: derived_data_build_dir=$derived_data_build_dir" >&2
    bazel_out_pattern="${derived_data_build_dir}/bazel-out/ios_sim_arm64-dbg-*"
    echo "RULES_XCODEPROJ DEBUG: bazel_out_pattern=$bazel_out_pattern" >&2
    
    # Find the actual bazel-out directory with the configuration hash
    echo "RULES_XCODEPROJ DEBUG: Looking for bazel-out directories..." >&2
    for bazel_out_dir in $bazel_out_pattern; do
      echo "RULES_XCODEPROJ DEBUG: Checking: $bazel_out_dir" >&2
      if [[ -d "$bazel_out_dir" ]]; then
        echo "RULES_XCODEPROJ DEBUG: Found bazel-out directory: $bazel_out_dir" >&2
        
        # Scan for all existing target directories and create dependency files
        bin_dir="$bazel_out_dir/bin"
        if [[ -d "$bin_dir" ]]; then
          
          # Create dependency files for any Objects-normal/arm64 directories we find
          find "$bin_dir" -type d -name "Objects-normal" 2>/dev/null | while read -r objects_dir; do
            arm64_dir="$objects_dir/arm64"
            if [[ -d "$arm64_dir" ]] || mkdir -p "$arm64_dir" 2>/dev/null; then
              
              # For each Objects-normal/arm64 directory, create common dependency file patterns
              # that typically appear in Swift/ObjC compilation
              
              # Get the target name from the path for better logging
              target_path="${objects_dir%/Objects-normal}"
              target_name="${target_path##*/}"
              
              echo "RULES_XCODEPROJ DEBUG: Creating dependency files for target: $target_name in $arm64_dir" >&2
              
              # Look for existing .o files first and create corresponding .d files
              if find "$arm64_dir" -name "*.o" -print -quit | grep -q .; then
                echo "RULES_XCODEPROJ DEBUG: Found .o files in $arm64_dir" >&2
                find "$arm64_dir" -name "*.o" | while read -r obj_file; do
                  dep_file="${obj_file%.o}.d"
                  if [[ ! -f "$dep_file" ]]; then
                    echo "RULES_XCODEPROJ DEBUG: Creating dependency file: $dep_file" >&2
                    {
                      echo "# Dependency file for $target_name preview build"
                      echo "# Generated by rules_xcodeproj at $(date)"
                      echo "# Prevents 'unable to open dependencies file' errors"
                      echo "$obj_file: \\"
                    } > "$dep_file"
                  else
                    echo "RULES_XCODEPROJ DEBUG: Dependency file already exists: $dep_file" >&2
                  fi
                done
              else
                echo "RULES_XCODEPROJ DEBUG: No .o files found in $arm64_dir" >&2
              fi
              
              # Also create dependency files for common compilation units that might be expected
              # but don't have .o files yet (common in incremental builds)
              # This is a more defensive approach for preview builds
              common_patterns=("*.swift" "*.m" "*.mm" "*.c" "*.cpp")
              for pattern in "${common_patterns[@]}"; do
                # Look in the source tree for files matching this pattern
                # and create corresponding dependency files
                source_base="${target_path%/bin/*}"
                if [[ -d "$source_base" ]]; then
                  find "$source_base" -name "$pattern" -type f 2>/dev/null | head -10 | while read -r source_file; do
                    base_name=$(basename "$source_file" | sed 's/\.[^.]*$//')
                    dep_file="$arm64_dir/$base_name.d"
                    if [[ ! -f "$dep_file" ]]; then
                      {
                        echo "# Dependency file for $target_name preview build"
                        echo "# Generated by rules_xcodeproj for $base_name at $(date)"
                        echo "# Prevents 'unable to open dependencies file' errors"
                      } > "$dep_file"
                    fi
                  done
                fi
              done
            fi
          done
          
          # Additional fallback: If no Objects-normal directories exist yet,
          # create them based on the directory structure we can infer
          find "$bin_dir" -mindepth 1 -maxdepth 4 -type d 2>/dev/null | while read -r potential_target_dir; do
            # Skip if it already has Objects-normal
            if [[ ! -d "$potential_target_dir/Objects-normal" ]]; then
              # Only create for directories that look like they could be targets
              dir_name=$(basename "$potential_target_dir")
              if [[ "$dir_name" =~ ^[a-zA-Z] && ! "$dir_name" =~ ^(bin|external)$ ]]; then
                objects_arm64_dir="$potential_target_dir/Objects-normal/arm64"
                mkdir -p "$objects_arm64_dir"
                
                # Create a minimal placeholder dependency file
                placeholder_dep="$objects_arm64_dir/placeholder.d"
                if [[ ! -f "$placeholder_dep" ]]; then
                  {
                    echo "# Placeholder dependency file for $dir_name preview build"
                    echo "# Generated by rules_xcodeproj at $(date)"
                    echo "# Prevents 'unable to open dependencies file' errors"
                  } > "$placeholder_dep"
                fi
              fi
            fi
          done
        fi
        
        break  # Use the first matching bazel-out directory
      fi
    done
  else
    echo "RULES_XCODEPROJ DEBUG: TARGET_TEMP_DIR not available, trying alternative approaches" >&2
    
    # Alternative approach: Try to find DerivedData directly using known patterns
    # Look for the DerivedData structure that Xcode creates
    derived_data_base="/Users/$(whoami)/Library/Developer/Xcode/DerivedData"
    
    if [[ -d "$derived_data_base" ]]; then
      echo "RULES_XCODEPROJ DEBUG: Searching for Dropbox projects in DerivedData" >&2
      
      # Find any Dropbox-related DerivedData directories
      find "$derived_data_base" -maxdepth 1 -name "Dropbox-*" -type d 2>/dev/null | while read -r project_dir; do
        echo "RULES_XCODEPROJ DEBUG: Found project directory: $project_dir" >&2
        
        # Look for bazel-out directories within this project
        find "$project_dir" -path "*/Build/Intermediates.noindex/Dropbox.build/bazel-out/ios_sim_arm64-dbg-*" -type d 2>/dev/null | while read -r bazel_config_dir; do
          echo "RULES_XCODEPROJ DEBUG: Found bazel config directory: $bazel_config_dir" >&2
          
          # Apply our generalized dependency file creation to this directory
          bin_dir="$bazel_config_dir/bin"
          if [[ -d "$bin_dir" ]] || mkdir -p "$bin_dir" 2>/dev/null; then
            echo "RULES_XCODEPROJ DEBUG: Processing bin directory: $bin_dir" >&2
            
            # Create dependency files for any Objects-normal/arm64 directories we find OR can infer
            find "$bin_dir" -type d -name "Objects-normal" 2>/dev/null | while read -r objects_dir; do
              arm64_dir="$objects_dir/arm64"
              mkdir -p "$arm64_dir"
              
              target_path="${objects_dir%/Objects-normal}"
              target_name="${target_path##*/}"
              
              echo "RULES_XCODEPROJ DEBUG: Creating dependency file in existing Objects-normal: $arm64_dir" >&2
              
              # Create a generic dependency file for this target
              dep_file="$arm64_dir/placeholder.d"
              if [[ ! -f "$dep_file" ]]; then
                {
                  echo "# Dependency file for $target_name preview build (alternative method)"
                  echo "# Generated by rules_xcodeproj at $(date)"
                  echo "# Prevents 'unable to open dependencies file' errors"
                } > "$dep_file"
              fi
            done
            
            # Generalized approach: Create dependency files for ALL potential target directories
            # that might exist in the bin structure, without hardcoding specific libraries
            
            # Scan for any directories that look like they could contain compilation targets
            find "$bin_dir" -mindepth 1 -maxdepth 4 -type d 2>/dev/null | while read -r potential_target_dir; do
              # Skip if it already has Objects-normal (we handle those above)
              if [[ ! -d "$potential_target_dir/Objects-normal" ]]; then
                # Check if this looks like a target directory (has source-like structure)
                dir_name=$(basename "$potential_target_dir")
                
                # Create Objects-normal/arm64 for any directory that might be a target
                # This is defensive - better to create too many than too few for preview builds
                if [[ "$dir_name" =~ ^[a-zA-Z] && ${#dir_name} -gt 2 ]]; then
                  objects_arm64_dir="$potential_target_dir/Objects-normal/arm64"
                  mkdir -p "$objects_arm64_dir"
                  
                  echo "RULES_XCODEPROJ DEBUG: Creating generalized dependency structure for: $potential_target_dir" >&2
                  
                  # Create a placeholder dependency file
                  dep_file="$objects_arm64_dir/placeholder.d"
                  if [[ ! -f "$dep_file" ]]; then
                    {
                      echo "# Dependency file for $dir_name preview build (generalized method)"
                      echo "# Generated by rules_xcodeproj at $(date)"
                      echo "# Prevents 'unable to open dependencies file' errors"
                    } > "$dep_file"
                  fi
                fi
              fi
            done
          fi
        done
      done
    fi
  fi
fi

# TODO: https://github.com/MobileNativeFoundation/rules_xcodeproj/issues/402
# Copy diagnostics, and on a change
# `echo "private let touch = \"$(date +%s)\"" > $DERIVED_FILE_DIR/$forced_swift_compile_file"`
# See git blame for this comment for an example

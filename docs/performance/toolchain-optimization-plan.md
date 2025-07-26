# CreateSymlinkToolchain Performance Optimization Plan

## Executive Summary

The `CreateSymlinkToolchain` Bazel action currently takes 30+ seconds to complete, significantly impacting build times. This document outlines a comprehensive optimization plan to reduce this time to 1-5 seconds through parallel processing, caching, and incremental updates.

## Problem Analysis

### Current Implementation

The bottleneck occurs in `xcodeproj/internal/templates/custom_toolchain_symlink.sh` at lines 88-91:

```bash
done < <(find "$DEFAULT_TOOLCHAIN" -type f -o -type l 2>/dev/null || {
    echo "Error: Failed to find files in $DEFAULT_TOOLCHAIN" >&2
    exit 1
})
```

### Performance Bottlenecks

1. **Massive File Discovery (15-30 seconds)**
   - `find` command scans entire Xcode toolchain directory
   - Typical path: `/Applications/Xcode.app/Contents/Developer/Toolchains/XcodeDefault.xctoolchain/`
   - Contains ~50,000+ files across complex directory structure
   - Single-threaded filesystem traversal

2. **Sequential Processing (10-20 seconds)**
   - Each file processed individually in bash while loop
   - 20,000+ individual `ln -sf` operations
   - Additional `mkdir -p` calls for each unique directory
   - No parallelization

3. **Retry Logic Overhead (5-10 seconds)**
   - Exponential backoff retry logic applied to every operation
   - Most operations succeed on first try, making retries unnecessary
   - 3 attempts × 20,000 operations = significant overhead

## Optimization Strategy

### Phase 1: Parallel Processing (Priority: High)

**Objective**: Replace sequential file processing with parallel batch operations

**Implementation A: xargs-based Parallel Processing**

```bash
# Replace sequential loop with parallel processing
process_files_parallel() {
    local batch_size=100
    local max_jobs=8
    
    find "$DEFAULT_TOOLCHAIN" -type f -o -type l 2>/dev/null | \
        while read -r file; do
            # Filter out overridden tools
            base_name=$(basename "$file")
            should_skip=0
            for tool_name in $(cat "$TOOL_NAMES_FILE"); do
                if [[ "$base_name" == "$tool_name" ]]; then
                    should_skip=1
                    break
                fi
            done
            [[ $should_skip -eq 0 ]] && echo "$file"
        done | \
        xargs -P "$max_jobs" -n "$batch_size" bash -c '
            for file in "$@"; do
                rel_path="${file#'"$DEFAULT_TOOLCHAIN"'/}"
                target_path="'"$TOOLCHAIN_DIR"'/$rel_path"
                target_dir="$(dirname "$target_path")"
                mkdir -p "$target_dir" 2>/dev/null || true
                ln -sf "$file" "$target_path" 2>/dev/null || true
            done
        ' _
}
```

**Implementation B: GNU Parallel (Advanced)**

```bash
# More sophisticated parallel processing using GNU parallel
process_files_gnu_parallel() {
    local max_jobs=8
    
    export DEFAULT_TOOLCHAIN TOOLCHAIN_DIR TOOL_NAMES_FILE
    
    find "$DEFAULT_TOOLCHAIN" -type f -o -type l 2>/dev/null | \
        parallel -j "$max_jobs" --pipe -N 50 '
            while read -r file; do
                base_name=$(basename "$file")
                should_skip=0
                for tool_name in $(cat "$TOOL_NAMES_FILE"); do
                    if [[ "$base_name" == "$tool_name" ]]; then
                        should_skip=1
                        break
                    fi
                done
                
                if [[ $should_skip -eq 0 ]]; then
                    rel_path="${file#$DEFAULT_TOOLCHAIN/}"
                    target_path="$TOOLCHAIN_DIR/$rel_path"
                    target_dir="$(dirname "$target_path")"
                    mkdir -p "$target_dir" 2>/dev/null || true
                    ln -sf "$file" "$target_path" 2>/dev/null || true
                fi
            done
        '
}
```

**Expected Performance Improvement**: 5-8x faster (3-6 seconds vs 30+ seconds)

### Phase 2: Caching Mechanism (Priority: High)

**Objective**: Cache toolchain file lists to avoid repeated filesystem scans

**Implementation**: Cache-based File Discovery

```bash
# Cache management functions
setup_toolchain_cache() {
    local cache_dir="$HOME/.cache/rules_xcodeproj/toolchain"
    local xcode_version_hash=$(echo "$XCODE_RAW_VERSION" | shasum -a 256 | cut -d' ' -f1)
    local cache_file="$cache_dir/toolchain_files_$xcode_version_hash.txt"
    
    mkdir -p "$cache_dir"
    
    # Clean up old cache files (older than 7 days)
    find "$cache_dir" -name "toolchain_files_*.txt" -mtime +7 -delete 2>/dev/null || true
    
    echo "$cache_file"
}

get_toolchain_files() {
    local cache_file=$(setup_toolchain_cache)
    
    # Check if cache is valid
    if [[ -f "$cache_file" && "$cache_file" -nt "$DEFAULT_TOOLCHAIN" ]]; then
        echo "Using cached toolchain file list..." >&2
        cat "$cache_file"
    else
        echo "Building toolchain file cache..." >&2
        find "$DEFAULT_TOOLCHAIN" -type f -o -type l 2>/dev/null | tee "$cache_file"
    fi
}

# Usage in main script
get_toolchain_files | while read -r file; do
    # Process files...
done
```

**Cache Key Strategy**:
- Key by Xcode version hash to handle version changes
- Check modification time against toolchain directory
- Automatic cleanup of stale cache entries

**Expected Performance Improvement**: 10-20x faster for subsequent builds (1-2 seconds vs 30+ seconds)

### Phase 3: Incremental Updates (Priority: Medium)

**Objective**: Only update changed files rather than recreating entire toolchain

**Implementation**: State-based Incremental Updates

```bash
# State management for incremental updates
setup_toolchain_state() {
    local cache_dir="$HOME/.cache/rules_xcodeproj/toolchain"
    local xcode_version_hash=$(echo "$XCODE_RAW_VERSION" | shasum -a 256 | cut -d' ' -f1)
    local state_file="$cache_dir/toolchain_state_$xcode_version_hash.json"
    
    mkdir -p "$cache_dir"
    echo "$state_file"
}

check_incremental_update() {
    local state_file=$(setup_toolchain_state)
    
    if [[ -f "$state_file" ]]; then
        # Load previous state
        local prev_tool_names=$(jq -r '.tool_names[]' "$state_file" 2>/dev/null || echo "")
        local prev_xcode_version=$(jq -r '.xcode_version' "$state_file" 2>/dev/null || echo "")
        
        # Check if only tool overrides changed
        if [[ "$prev_xcode_version" == "$XCODE_VERSION" ]]; then
            local current_tool_names=$(cat "$TOOL_NAMES_FILE" | tr '\n' ' ')
            local previous_tool_names=$(echo "$prev_tool_names" | tr '\n' ' ')
            
            if [[ "$current_tool_names" == "$previous_tool_names" ]]; then
                echo "No changes detected, skipping toolchain update" >&2
                return 0
            else
                echo "Tool overrides changed, performing incremental update" >&2
                update_changed_tools_only "$prev_tool_names"
                return 0
            fi
        fi
    fi
    
    return 1  # Full update needed
}

update_changed_tools_only() {
    local prev_tool_names="$1"
    local current_tool_names=$(cat "$TOOL_NAMES_FILE")
    
    # Remove old overrides
    echo "$prev_tool_names" | while read -r tool_name; do
        if [[ -n "$tool_name" ]]; then
            find "$TOOLCHAIN_DIR" -name "$tool_name" -type l -delete 2>/dev/null || true
        fi
    done
    
    # Add new overrides (handled by existing override logic)
    echo "Incremental update completed" >&2
}

save_toolchain_state() {
    local state_file=$(setup_toolchain_state)
    
    jq -n --arg xcode_version "$XCODE_VERSION" \
          --argjson tool_names "$(cat "$TOOL_NAMES_FILE" | jq -R . | jq -s .)" \
          '{xcode_version: $xcode_version, tool_names: $tool_names}' > "$state_file"
}

# Usage in main script
if check_incremental_update; then
    exit 0
fi

# ... perform full update ...

save_toolchain_state
```

**Expected Performance Improvement**: 50-100x faster for override-only changes (0.1-0.5 seconds)

### Phase 4: Advanced Optimizations (Priority: Low)

**A. rsync-based Bulk Operations**

```bash
# Use rsync for initial directory structure copying
bulk_copy_with_rsync() {
    local exclusion_file=$(mktemp)
    
    # Create exclusion file for overridden tools
    cat "$TOOL_NAMES_FILE" | sed 's/^/usr\/bin\//' > "$exclusion_file"
    
    # Bulk copy with exclusions
    rsync -a --exclude-from="$exclusion_file" \
          --exclude="ToolchainInfo.plist" \
          "$DEFAULT_TOOLCHAIN/" "$TOOLCHAIN_DIR/"
    
    rm -f "$exclusion_file"
}
```

**B. Hardlinks vs Symlinks**

```bash
# Use hardlinks where possible (faster creation)
create_link_optimized() {
    local src="$1"
    local dest="$2"
    
    # Try hardlink first (faster), fall back to symlink
    ln "$src" "$dest" 2>/dev/null || ln -sf "$src" "$dest"
}
```

**C. APFS Cloning on macOS**

```bash
# Use APFS cloning for instantaneous copies
clone_with_apfs() {
    local src="$1"
    local dest="$2"
    
    # Use cp -c for APFS cloning (macOS 10.13+)
    if command -v cp >/dev/null 2>&1; then
        cp -c "$src" "$dest" 2>/dev/null || cp "$src" "$dest"
    else
        cp "$src" "$dest"
    fi
}
```

### Phase 5: Bazel Integration Improvements (Priority: Low)

**A. Better Caching in Bazel**

```python
# In xcodeproj/internal/custom_toolchain.bzl
ctx.actions.run_shell(
    inputs = bazel_integration_files,
    outputs = [symlink_toolchain_dir],
    tools = [symlink_script_file],
    mnemonic = "CreateSymlinkToolchain",
    command = symlink_script_file.path,
    execution_requirements = {
        "local": "1",
        "no-cache": "0",  # Enable caching with proper cache key
        "no-sandbox": "1",
        "requires-darwin": "1",
    },
    use_default_shell_env = True,
)
```

**B. Persistent Workers**

```python
# Implement toolchain creation as a persistent Bazel worker
def _create_toolchain_worker():
    # Keep toolchain state in memory between invocations
    # Only recreate when Xcode version or overrides change
    pass
```

## Implementation Roadmap

### Phase 1 (Immediate Impact): Parallel Processing
- **Effort**: 1-2 days
- **Impact**: 5-8x improvement
- **Risk**: Low
- **Files to modify**: `xcodeproj/internal/templates/custom_toolchain_symlink.sh`

### Phase 2 (High Impact): Caching
- **Effort**: 2-3 days
- **Impact**: 10-20x improvement for subsequent builds
- **Risk**: Medium (cache invalidation complexity)
- **Files to modify**: `xcodeproj/internal/templates/custom_toolchain_symlink.sh`

### Phase 3 (Optimization): Incremental Updates
- **Effort**: 3-4 days
- **Impact**: 50-100x improvement for override-only changes
- **Risk**: Medium (state management complexity)
- **Files to modify**: `xcodeproj/internal/templates/custom_toolchain_symlink.sh`, `xcodeproj/internal/custom_toolchain.bzl`

### Phase 4 (Advanced): Additional Optimizations
- **Effort**: 1-2 weeks
- **Impact**: 2-3x additional improvement
- **Risk**: High (platform-specific features)
- **Files to modify**: Multiple files across the codebase

## Performance Benchmarks

### Expected Results

| Phase | Current Time | Optimized Time | Improvement |
|-------|--------------|----------------|-------------|
| Baseline | 30-60s | 30-60s | 1x |
| Phase 1 (Parallel) | 30-60s | 5-10s | 5-8x |
| Phase 2 (Caching) | 5-10s | 1-2s | 10-20x |
| Phase 3 (Incremental) | 1-2s | 0.1-0.5s | 50-100x |
| Phase 4 (Advanced) | 0.1-0.5s | 0.05-0.2s | 2-3x |

### Measurement Strategy

```bash
# Benchmarking script
benchmark_toolchain_creation() {
    local phase="$1"
    local runs=5
    local total_time=0
    
    for i in $(seq 1 $runs); do
        echo "Run $i of $runs..."
        rm -rf "$TOOLCHAIN_DIR" 2>/dev/null || true
        
        start_time=$(date +%s.%N)
        # Run toolchain creation
        ./custom_toolchain_symlink.sh
        end_time=$(date +%s.%N)
        
        run_time=$(echo "$end_time - $start_time" | bc)
        total_time=$(echo "$total_time + $run_time" | bc)
        echo "Run $i: ${run_time}s"
    done
    
    average_time=$(echo "scale=2; $total_time / $runs" | bc)
    echo "Phase $phase average: ${average_time}s"
}
```

## Testing Strategy

### Unit Tests

```bash
# Test parallel processing
test_parallel_processing() {
    # Create test toolchain with known file count
    # Verify all files are processed correctly
    # Compare sequential vs parallel results
}

# Test caching mechanism
test_caching() {
    # Verify cache creation and invalidation
    # Test cache key generation
    # Verify cache cleanup
}

# Test incremental updates
test_incremental_updates() {
    # Verify state tracking
    # Test override-only changes
    # Test full update triggers
}
```

### Integration Tests

```bash
# Test with real Xcode toolchain
test_real_toolchain() {
    # Run against actual Xcode installation
    # Verify generated toolchain functionality
    # Test with different Xcode versions
}
```

## Risk Mitigation

### Compatibility Risks
- **Risk**: Different macOS/Xcode versions
- **Mitigation**: Extensive testing across versions, feature detection

### Performance Risks
- **Risk**: Caching overhead exceeding benefits
- **Mitigation**: Benchmarking, cache size limits, cleanup mechanisms

### Reliability Risks
- **Risk**: Parallel processing race conditions
- **Mitigation**: Atomic operations, proper error handling, fallback mechanisms

## Monitoring and Metrics

### Key Metrics
- Toolchain creation time
- Cache hit/miss rates
- Incremental update frequency
- Error rates

### Alerting
- Toolchain creation time > 10 seconds
- Cache miss rate > 50%
- Error rate > 1%

## Conclusion

This optimization plan provides a clear path to dramatically improve CreateSymlinkToolchain performance from 30+ seconds to under 1 second through incremental improvements. The phased approach allows for gradual implementation while maintaining system stability.

The most impactful changes (parallel processing and caching) can be implemented quickly with low risk, while more advanced optimizations can be added over time as development capacity allows.
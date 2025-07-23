# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project Overview

This is `rules_xcodeproj`, a Bazel ruleset that generates Xcode projects from Bazel targets. It's maintained by the Mobile Native Foundation and used by major companies like Lyft, Slack, Spotify, and Robinhood for iOS/macOS development with Bazel.

## Key Commands

### Building and Testing
- `bazel build //tools/...` - Build all tools
- `bazel test //tools/...` - Run all tool tests  
- `bazel test //test/internal/xcschemes:all` - Run internal tests
- `bazel test //tools/params_processors:all` - Run parameter processor tests

### Code Quality
- `bazel run //:buildifier.fix` - Format and fix Bazel files
- `bazel run //:buildifier.check` - Check Bazel file formatting
- `./docs/update_docs.sh` - Generate documentation from code comments

### Project Generation
- `bazel run //tools:xcodeproj` - Generate development Xcode project for this repo
- `bazel run //:xcodeproj` - Generate Xcode project (from example directories)
- `bazel run //examples/integration:xcodeproj` - Generate integration example project

### Development Testing
- `cd examples/integration; bazel run //:xcodeproj` - Test changes in example projects
- `bazel run //examples/cc:xcodeproj` - Test C++ example

## Architecture

### Core Components
- **`xcodeproj/`** - Main Bazel rules and library code
  - `xcodeproj.bzl` - Main public API and xcodeproj rule
  - `internal/` - Implementation details, aspects, and internal rules
  - `internal/xcodeproj_aspect.bzl` - Core aspect that analyzes Bazel targets
  - `internal/xcodeproj_rule.bzl` - Main rule implementation

### Code Generation Tools (Swift)
Located in `tools/generators/`, these Swift executables generate different parts of Xcode projects:

- **`files_and_groups/`** - Generates file references and group structure
- **`pbxnativetargets/`** - Creates native target definitions and build phases  
- **`pbxproj_prefix/`** - Generates project file headers and global settings
- **`pbxtargetdependencies/`** - Handles target dependencies and consolidation
- **`swift_debug_settings/`** - Processes Swift debug compilation settings
- **`target_build_settings/`** - Generates Xcode build settings from Bazel flags
- **`xcschemes/`** - Creates Xcode schemes for building/testing/debugging

### Bazel Integration
- **`internal/bazel_integration_files/`** - Scripts and tools for Bazel/Xcode integration
  - Shell scripts for building, copying outputs, creating debug files
  - Python scripts for processing build logs and calculating dependencies

### Supporting Tools
- **`tools/import_indexstores/`** - Swift tool for importing Bazel index stores to Xcode
- **`tools/params_processors/`** - Python modules for processing compiler parameters
- **`tools/swiftc_stub/`** - Swift compiler stub for Xcode integration

## Development Workflow

### Making Changes
1. Edit code in appropriate directory (`xcodeproj/` for rules, `tools/` for generators)
2. Test locally: `bazel test //tools/...` and `bazel run //examples/integration:xcodeproj`
3. Run formatter: `bazel run //:buildifier.fix`
4. Update docs if needed: `./docs/update_docs.sh`

### Testing External Projects
Add to `.bazelrc` in external project:
```
# With bzlmod:
build --override_module=rules_xcodeproj=/path/to/rules_xcodeproj
# Without bzlmod:  
build --override_repository=rules_xcodeproj=/path/to/rules_xcodeproj
```

## Important Files
- `shared.bazelrc` - Common Bazel configuration
- `MODULE.bazel` - Bzlmod module definition with dependencies
- `examples/` - Example projects demonstrating usage patterns
- `test/` - Unit tests for internal functionality
- Python test files use unittest framework (e.g., `tools/params_processors/*_tests.py`)

## Notes
- Swift tools use ArgumentParser and OrderedCollections dependencies
- Most code generation happens via Swift executables rather than Starlark
- The project uses Bazel's aspects heavily to analyze build graphs
- Focus on "rules_xcodeproj needs toplevel to download needed outputs" (see shared.bazelrc)
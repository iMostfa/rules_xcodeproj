import Foundation

/// Utilities for working with Xcode installations and toolchains.
public enum XcodeUtils {
    
    // MARK: - Cache Storage
    private static var cachedDeveloperPath: String?
    private static var cachedClangVersions: [String: String] = [:]
    
    /// Gets the current Xcode developer directory path using `xcode-select -p`.
    ///
    /// - Returns: The path to the current Xcode developer directory.
    ///            Falls back to `/Applications/Xcode.app/Contents/Developer` if `xcode-select` fails.
    public static func getDeveloperPath() -> String {
        if let cached = cachedDeveloperPath {
            return cached
        }
        
        let process = Process()
        process.launchPath = "/usr/bin/xcode-select"
        process.arguments = ["-p"]
        
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        
        do {
            try process.run()
            process.waitUntilExit()
            
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            if let output = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines),
               !output.isEmpty,
               process.terminationStatus == 0 {
                cachedDeveloperPath = output
                return output
            }
        } catch {
            // Fall through to default
        }
        
        // Fallback to default Xcode path
        let defaultPath = "/Applications/Xcode.app/Contents/Developer"
        cachedDeveloperPath = defaultPath
        return defaultPath
    }
    
    /// Gets the latest available Clang version for the given Xcode developer path.
    ///
    /// - Parameter xcodeDevPath: The Xcode developer directory path.
    /// - Returns: The highest available Clang version number as a string.
    ///            Falls back to "16" if no versions are found.
    public static func getClangVersion(xcodeDevPath: String) -> String {
        if let cached = cachedClangVersions[xcodeDevPath] {
            return cached
        }
        
        let clangLibPath = "\(xcodeDevPath)/Toolchains/XcodeDefault.xctoolchain/usr/lib/clang"
        
        do {
            let contents = try FileManager.default.contentsOfDirectory(atPath: clangLibPath)
            // Filter and sort version directories (e.g., "16", "17")
            let versions = contents
                .compactMap { Int($0) }
                .sorted(by: >)
            
            if let latestVersion = versions.first {
                let versionString = String(latestVersion)
                cachedClangVersions[xcodeDevPath] = versionString
                return versionString
            }
        } catch {
            // Fall through to default
        }
        
        // Fallback to version 16
        let fallbackVersion = "16"
        cachedClangVersions[xcodeDevPath] = fallbackVersion
        return fallbackVersion
    }
    
    /// Constructs the full path to the clang runtime library for iOS simulator.
    ///
    /// - Parameter xcodeDevPath: The Xcode developer directory path. If nil, uses `getDeveloperPath()`.
    /// - Returns: The full path to `libclang_rt.iossim.a`.
    public static func getClangRuntimePath(xcodeDevPath: String? = nil) -> String {
        let devPath = xcodeDevPath ?? getDeveloperPath()
        let clangVersion = getClangVersion(xcodeDevPath: devPath)
        return "\(devPath)/Toolchains/XcodeDefault.xctoolchain/usr/lib/clang/\(clangVersion)/lib/darwin/libclang_rt.iossim.a"
    }
    
    /// Constructs the path to the clang library directory for build settings.
    ///
    /// - Parameter xcodeDevPath: The Xcode developer directory path. If nil, uses `getDeveloperPath()`.
    /// - Returns: The quoted path to the clang library directory.
    public static func getClangLibraryPath(xcodeDevPath: String? = nil) -> String {
        let devPath = xcodeDevPath ?? getDeveloperPath()
        let clangVersion = getClangVersion(xcodeDevPath: devPath)
        return "\"\(devPath)/Toolchains/XcodeDefault.xctoolchain/usr/lib/clang/\(clangVersion)/lib/darwin\""
    }
}

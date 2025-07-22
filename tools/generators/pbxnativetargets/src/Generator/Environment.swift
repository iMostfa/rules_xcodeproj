import PBXProj
import ToolCommon

/// Registry for tracking shared framework objects to avoid duplication in the project file.
class SharedFrameworkRegistry {
    private var frameworkObjects: [String: Object] = [:]
    private var buildFileObjects: [String: Object] = [:]
    
    /// Gets or creates a shared framework object for the given path.
    func getOrCreateFrameworkObject(
        path: BazelPath,
        createFrameworkObject: Generator.CreateFrameworkObject,
        createBuildFileSubIdentifier: Generator.CreateBuildFileSubIdentifier,
        shard: UInt8
    ) -> (frameworkObject: Object, frameworkSubIdentifier: Identifiers.BuildFiles.SubIdentifier) {
        let key = path.path
        let frameworkSubIdentifier = createBuildFileSubIdentifier(path, type: .framework, shard: shard)
        
        if let existingFramework = frameworkObjects[key] {
            return (existingFramework, frameworkSubIdentifier)
        }
        
        let frameworkObject = createFrameworkObject(frameworkPath: path, subIdentifier: frameworkSubIdentifier)
        frameworkObjects[key] = frameworkObject
        return (frameworkObject, frameworkSubIdentifier)
    }
    
    /// Gets or creates a shared build file object for the given framework.
    func getOrCreateBuildFileObject(
        frameworkPath: BazelPath,
        frameworkSubIdentifier: Identifiers.BuildFiles.SubIdentifier,
        createFrameworkBuildFileObject: Generator.CreateFrameworkBuildFileObject,
        createBuildFileSubIdentifier: Generator.CreateBuildFileSubIdentifier,
        shard: UInt8
    ) -> (buildFileObject: Object, buildFileSubIdentifier: Identifiers.BuildFiles.SubIdentifier) {
        let key = "\(frameworkPath.path)_buildfile"
        let buildFileSubIdentifier = createBuildFileSubIdentifier(
            BazelPath(frameworkPath.path.split(separator: "/").last.map(String.init)!),
            type: .framework,
            shard: shard
        )
        
        if let existingBuildFile = buildFileObjects[key] {
            return (existingBuildFile, buildFileSubIdentifier)
        }
        
        let buildFileObject = createFrameworkBuildFileObject(
            frameworkSubIdentifier: frameworkSubIdentifier,
            subIdentifier: buildFileSubIdentifier
        )
        buildFileObjects[key] = buildFileObject
        return (buildFileObject, buildFileSubIdentifier)
    }
    
    /// Returns all shared framework objects that have been created.
    func getAllFrameworkObjects() -> [Object] {
        return Array(frameworkObjects.values)
    }
    
    /// Returns all shared build file objects that have been created.
    func getAllBuildFileObjects() -> [Object] {
        return Array(buildFileObjects.values)
    }
}

extension Generator {
    /// Provides the callable dependencies for `Generator`.
    ///
    /// The main purpose of `Environment` is to enable dependency injection,
    /// allowing for different implementations to be used in tests.
    struct Environment {
        let calculatePartial: CalculatePartial
        let createTarget: CreateTarget
        let write: Write
        let writeBuildFileSubIdentifiers: WriteBuildFileSubIdentifiers
        let sharedFrameworkRegistry: SharedFrameworkRegistry
    }
}

extension Generator.Environment {
    static let `default`: Generator.Environment = {
        let sharedFrameworkRegistry = SharedFrameworkRegistry()
        return Self(
            calculatePartial: Generator.CalculatePartial(),
            createTarget: Generator.CreateTarget(
                calculatePlatformVariants: Generator.CalculatePlatformVariants(),
                createBuildPhases: Generator.CreateBuildPhases(
                    createBazelIntegrationBuildPhaseObject:
                        Generator.CreateBazelIntegrationBuildPhaseObject(),
                    createBuildFileSubIdentifier:
                        Generator.CreateBuildFileSubIdentifier(),
                    createCreateCompileDependenciesBuildPhaseObject:
                        Generator.CreateCreateCompileDependenciesBuildPhaseObject(),
                    createCreateLinkDependenciesBuildPhaseObject:
                        Generator.CreateCreateLinkDependenciesBuildPhaseObject(),
                    createEmbedAppExtensionsBuildPhaseObject:
                        Generator.CreateEmbedAppExtensionsBuildPhaseObject(),
                    createProductBuildFileObject:
                        Generator.CreateProductBuildFileObject(),
                    createSourcesBuildPhaseObject:
                        Generator.CreateSourcesBuildPhaseObject(),
                    createLinkBinaryWithLibrariesBuildPhaseObject:
                        Generator.CreateLinkBinaryWithLibrariesBuildPhaseObject(),
                    createFrameworkObject: Generator.CreateFrameworkObject(),
                    createFrameworkBuildFileObject:
                        Generator.CreateFrameworkBuildFileObject()
                ),
                createProductObject: Generator.CreateProductObject(),
                createTargetObject: Generator.CreateTargetObject(),
                createXcodeConfigurations: Generator.CreateXcodeConfigurations(
                    calculatePlatformVariantBuildSettings:
                        Generator.CalculatePlatformVariantBuildSettings(),
                    calculateSharedBuildSettings:
                        Generator.CalculateSharedBuildSettings(),
                    calculateXcodeConfigurationBuildSettings:
                        Generator.CalculateXcodeConfigurationBuildSettings(),
                    createBuildConfigurationListObject:
                        Generator.CreateBuildConfigurationListObject(),
                    createBuildConfigurationObject:
                        Generator.CreateBuildConfigurationObject(),
                    createBuildSettingsAttribute: CreateBuildSettingsAttribute()
                ),
                sharedFrameworkRegistry: sharedFrameworkRegistry
            ),
            write: Write(),
            writeBuildFileSubIdentifiers: Generator.WriteBuildFileSubIdentifiers(),
            sharedFrameworkRegistry: sharedFrameworkRegistry
        )
    }()
}

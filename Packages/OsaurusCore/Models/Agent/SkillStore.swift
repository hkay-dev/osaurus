//
//  SkillStore.swift
//  osaurus
//
//  Persistence for Skills using directory-based storage following Agent Skills spec.
//  Directory structure: skills/{skill-name}/SKILL.md with optional references/ and assets/
//

import CryptoKit
import Foundation

/// Errors from skill file path validation before a caller-controlled path can
/// reach the filesystem.
public enum SkillStoreFileError: Error, LocalizedError, Sendable, Equatable {
    case invalidRelativePath
    case pathEscapesDirectory
    case cannotModifyExternalSkill

    public var errorDescription: String? {
        switch self {
        case .invalidRelativePath: return "Skill file path must be a non-empty relative path"
        case .pathEscapesDirectory: return "Skill file path escapes its containing directory"
        case .cannotModifyExternalSkill: return "External skills are read-only"
        }
    }
}

public struct ExternalSkillRoot: Codable, Sendable, Equatable {
    public var id: String
    public var path: String
    public var enabled: Bool

    public init(id: String, path: String, enabled: Bool = true) {
        self.id = id
        self.path = path
        self.enabled = enabled
    }
}

extension ExternalSkillRoot {
    var url: URL {
        URL(fileURLWithPath: Self.expandedPath(path), isDirectory: true)
            .resolvingSymlinksInPath()
            .standardizedFileURL
    }

    private static func expandedPath(_ path: String) -> String {
        if path == "~" {
            return FileManager.default.homeDirectoryForCurrentUser.path
        }
        if path.hasPrefix("~/") {
            return FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent(String(path.dropFirst(2)))
                .path
        }
        return path
    }
}

private struct ExternalSkillRootsConfig: Codable {
    var roots: [ExternalSkillRoot]
}

public enum SkillStore {

    // MARK: - Public API

    /// Load all skills sorted by name, including built-ins
    public static func loadAll() async -> [Skill] {
        let directory = skillsDirectory()
        OsaurusPaths.ensureExistsSilent(directory)
        migrateOldFormat()

        var savedSkills: [UUID: Skill] = [:]

        savedSkills.merge(loadSkills(from: directory), uniquingKeysWith: { first, _ in first })

        for root in externalSkillRoots() where root.enabled {
            savedSkills.merge(loadSkills(from: root.url, sourceRoot: root), uniquingKeysWith: { first, _ in first })
        }

        // Load built-in skill states (hidden directories starting with .)
        var builtInStates: [UUID: Skill] = [:]
        if let contents = try? FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: []  // Include hidden files
        ) {
            for item in contents {
                let name = item.lastPathComponent
                // Only process hidden directories that look like UUIDs
                guard name.hasPrefix("."),
                    name.count > 1,
                    let skill = loadFromDirectory(item)
                else {
                    continue
                }
                builtInStates[skill.id] = skill
            }
        }

        // Merge built-in skills with saved state
        var skills: [Skill] = Skill.builtInSkills.map { builtIn in
            if let saved = builtInStates[builtIn.id] {
                return Skill(
                    id: builtIn.id,
                    name: builtIn.name,
                    description: builtIn.description,
                    version: builtIn.version,
                    author: builtIn.author,
                    category: builtIn.category,
                    enabled: saved.enabled,
                    instructions: builtIn.instructions,
                    isBuiltIn: true,
                    createdAt: builtIn.createdAt,
                    updatedAt: saved.updatedAt,
                    references: builtIn.references,
                    assets: builtIn.assets,
                    directoryName: builtIn.directoryName
                )
            }
            return builtIn
        }

        // Add custom skills
        let builtInIds = Set(Skill.builtInSkills.map { $0.id })
        for (id, skill) in savedSkills where !builtInIds.contains(id) {
            skills.append(skill)
        }

        return skills.sorted { a, b in
            if a.isBuiltIn != b.isBuiltIn { return a.isBuiltIn }
            return a.name.localizedCaseInsensitiveCompare(b.name) == .orderedAscending
        }
    }

    /// Load a specific skill by ID
    public static func load(id: UUID) async -> Skill? {
        if let builtIn = Skill.builtInSkills.first(where: { $0.id == id }) {
            return builtIn
        }

        return await loadAll().first { $0.id == id }
    }

    /// Save a skill to disk
    public static func save(_ skill: Skill) async {
        if skill.isBuiltIn {
            saveBuiltInState(skill)
            return
        }
        guard !skill.isExternal else { return }

        let slug = skill.xplaceholder_agentSkillsNamex
        var skillDir = skillsDirectory().appendingPathComponent(slug)

        if let oldName = skill.directoryName, oldName != slug {
            let oldDir = skillsDirectory().appendingPathComponent(oldName)
            let oldExists = FileManager.default.fileExists(atPath: oldDir.path)
            let targetExists = FileManager.default.fileExists(atPath: skillDir.path)
            if oldExists && !targetExists {
                try? FileManager.default.moveItem(at: oldDir, to: skillDir)
            } else if oldExists {
                skillDir = oldDir
            }
        }

        do {
            try FileManager.default.createDirectory(at: skillDir, withIntermediateDirectories: true)

            let skillMdPath = skillDir.appendingPathComponent("SKILL.md")
            try skill.toAgentSkillsFormatWithId().write(to: skillMdPath, atomically: true, encoding: .utf8)

            if !skill.references.isEmpty {
                try FileManager.default.createDirectory(
                    at: skillDir.appendingPathComponent("references"),
                    withIntermediateDirectories: true
                )
            }
            if !skill.assets.isEmpty {
                try FileManager.default.createDirectory(
                    at: skillDir.appendingPathComponent("assets"),
                    withIntermediateDirectories: true
                )
            }
        } catch {
            print("[Osaurus] Failed to save skill \(skill.id): \(error)")
        }
    }

    /// Delete a skill by ID
    @discardableResult
    public static func delete(id: UUID) async -> Bool {
        guard !Skill.builtInSkills.contains(where: { $0.id == id }) else {
            return false
        }

        let directory = skillsDirectory()
        guard
            let contents = try? FileManager.default.contentsOfDirectory(
                at: directory,
                includingPropertiesForKeys: [.isDirectoryKey],
                options: [.skipsHiddenFiles]
            )
        else {
            return false
        }

        for item in contents {
            var isDirectory: ObjCBool = false
            guard FileManager.default.fileExists(atPath: item.path, isDirectory: &isDirectory),
                isDirectory.boolValue,
                let skill = loadFromDirectory(item),
                skill.id == id
            else {
                continue
            }
            do {
                try FileManager.default.removeItem(at: item)
                return true
            } catch {
                return false
            }
        }
        return false
    }

    /// Check if a skill exists
    public static func exists(id: UUID) async -> Bool {
        if Skill.builtInSkills.contains(where: { $0.id == id }) {
            return true
        }
        return await load(id: id) != nil
    }

    /// Get the directory URL for a skill
    public static func skillDirectory(for skill: Skill) -> URL {
        if let url = skill.sourceDirectoryURL {
            return url
        }
        var dirName = skill.directoryName ?? skill.xplaceholder_agentSkillsNamex
        if dirName.isEmpty {
            dirName = "skill-\(skill.id.uuidString.prefix(8).lowercased())"
        }
        return skillsDirectory().appendingPathComponent(dirName)
    }

    // MARK: - File Operations

    /// Add a reference file to a skill
    public static func addReference(to skill: Skill, name: String, content: Data) async throws {
        guard !skill.isExternal else { throw SkillStoreFileError.cannotModifyExternalSkill }
        let refsDir = skillDirectory(for: skill).appendingPathComponent("references")
        try writeSkillFile(content, named: name, in: refsDir)
    }

    /// Add an asset file to a skill
    public static func addAsset(to skill: Skill, name: String, content: Data) async throws {
        guard !skill.isExternal else { throw SkillStoreFileError.cannotModifyExternalSkill }
        let assetsDir = skillDirectory(for: skill).appendingPathComponent("assets")
        try writeSkillFile(content, named: name, in: assetsDir)
    }

    /// Remove a file from a skill
    public static func removeFile(from skill: Skill, relativePath: String) async throws {
        guard !skill.isExternal else { throw SkillStoreFileError.cannotModifyExternalSkill }
        let skillDir = skillDirectory(for: skill)
        let fileURL = try containedFileURL(for: relativePath, in: skillDir)
        try ensureResolvedContainment(of: fileURL, in: skillDir)
        try FileManager.default.removeItem(at: fileURL)
    }

    /// Read content of a skill file
    public static func readFile(from skill: Skill, relativePath: String) async throws -> Data {
        let skillDir = skillDirectory(for: skill)
        let fileURL = try containedFileURL(for: relativePath, in: skillDir)
        try ensureResolvedContainment(of: fileURL, in: skillDir)
        return try Data(contentsOf: fileURL)
    }

    // MARK: - Private

    private static func skillsDirectory() -> URL {
        OsaurusPaths.skills()
    }

    public static func externalSkillRoots() -> [ExternalSkillRoot] {
        guard let data = try? Data(contentsOf: externalSkillRootsConfigURL()),
            let config = try? JSONDecoder().decode(ExternalSkillRootsConfig.self, from: data)
        else {
            return []
        }

        return normalizedExternalSkillRoots(config.roots)
    }

    @discardableResult
    public static func addExternalSkillRoot(path: String) throws -> ExternalSkillRoot {
        let newRoot = ExternalSkillRoot(id: externalSkillRootId(for: path), path: path)
        var roots = externalSkillRoots()
        if let existing = roots.first(where: { $0.url.path == newRoot.url.path }) {
            return existing
        }
        roots.append(newRoot)
        try saveExternalSkillRoots(roots)
        return newRoot
    }

    public static func removeExternalSkillRoot(id: String) throws {
        try saveExternalSkillRoots(externalSkillRoots().filter { $0.id != id })
    }

    public static func saveExternalSkillRoots(_ roots: [ExternalSkillRoot]) throws {
        let url = externalSkillRootsConfigURL()
        OsaurusPaths.ensureExistsSilent(url.deletingLastPathComponent())
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(ExternalSkillRootsConfig(roots: normalizedExternalSkillRoots(roots)))
            .write(to: url, options: .atomic)
    }

    private static func normalizedExternalSkillRoots(_ roots: [ExternalSkillRoot]) -> [ExternalSkillRoot] {
        var seen = Set<String>()
        var seenPaths = Set<String>()
        return roots.compactMap { root in
            let id = root.id.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !id.isEmpty, !root.path.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                seen.insert(id).inserted,
                seenPaths.insert(root.url.path).inserted
            else {
                return nil
            }
            var normalized = root
            normalized.id = id
            return normalized
        }
    }

    private static func externalSkillRootId(for path: String) -> String {
        let base =
            URL(fileURLWithPath: path, isDirectory: true).lastPathComponent
            .lowercased()
            .replacingOccurrences(of: "_", with: "-")
            .components(separatedBy: CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-")).inverted)
            .joined()
            .trimmingCharacters(in: CharacterSet(charactersIn: "-"))
        let digest = Array(SHA256.hash(data: Data(path.utf8))).prefix(4)
            .map { String(format: "%02x", $0) }
            .joined()
        return "\((base.isEmpty ? "external-skills" : base))-\(digest)"
    }

    private static func externalSkillRootsConfigURL() -> URL {
        OsaurusPaths.config().appendingPathComponent("skill-roots.json")
    }

    private static func writeSkillFile(_ content: Data, named name: String, in baseDirectory: URL) throws {
        let fileURL = try containedFileURL(for: name, in: baseDirectory)
        try createContainedParentDirectories(for: fileURL, in: baseDirectory)
        try ensureResolvedContainment(of: fileURL, in: baseDirectory)
        try content.write(to: fileURL)
    }

    private static func containedFileURL(for relativePath: String, in baseDirectory: URL) throws -> URL {
        let normalizedPath = try normalizedRelativeSkillFilePath(relativePath)
        let baseURL = baseDirectory.standardizedFileURL
        let fileURL = baseURL.appendingPathComponent(normalizedPath).standardizedFileURL

        guard isContained(fileURL, in: baseURL) else {
            throw SkillStoreFileError.pathEscapesDirectory
        }
        return fileURL
    }

    private static func normalizedRelativeSkillFilePath(_ relativePath: String) throws -> String {
        guard !relativePath.isEmpty,
            !(relativePath as NSString).isAbsolutePath
        else {
            throw SkillStoreFileError.invalidRelativePath
        }

        let rawComponents = relativePath.split(separator: "/", omittingEmptySubsequences: false)
        guard !rawComponents.contains("..") else {
            throw SkillStoreFileError.invalidRelativePath
        }

        let normalizedComponents =
            rawComponents
            .map(String.init)
            .filter { !$0.isEmpty && $0 != "." }
        guard !normalizedComponents.isEmpty else {
            throw SkillStoreFileError.invalidRelativePath
        }
        return normalizedComponents.joined(separator: "/")
    }

    private static func createContainedParentDirectories(for fileURL: URL, in baseDirectory: URL) throws {
        let fileManager = FileManager.default
        let baseURL = baseDirectory.standardizedFileURL
        let fileComponents = fileURL.standardizedFileURL.pathComponents
        let baseComponents = baseURL.pathComponents
        let parentComponents = Array(fileComponents.dropFirst(baseComponents.count).dropLast())

        try fileManager.createDirectory(at: baseURL, withIntermediateDirectories: true)
        guard !isSymbolicLink(baseURL) else {
            throw SkillStoreFileError.pathEscapesDirectory
        }

        var current = baseURL
        for component in parentComponents {
            current = current.appendingPathComponent(component, isDirectory: true)
            guard isContained(current, in: baseURL),
                !isSymbolicLink(current)
            else {
                throw SkillStoreFileError.pathEscapesDirectory
            }

            if !fileManager.fileExists(atPath: current.path) {
                try fileManager.createDirectory(at: current, withIntermediateDirectories: false)
            }

            var isDirectory: ObjCBool = false
            guard fileManager.fileExists(atPath: current.path, isDirectory: &isDirectory),
                isDirectory.boolValue
            else {
                throw SkillStoreFileError.invalidRelativePath
            }
        }
    }

    private static func ensureResolvedContainment(of fileURL: URL, in baseDirectory: URL) throws {
        let resolvedBase = baseDirectory.resolvingSymlinksInPath().standardizedFileURL
        let resolvedFile = fileURL.resolvingSymlinksInPath().standardizedFileURL
        guard isContained(resolvedFile, in: resolvedBase) else {
            throw SkillStoreFileError.pathEscapesDirectory
        }
    }

    private static func isContained(_ fileURL: URL, in baseDirectory: URL) -> Bool {
        let fileComponents = fileURL.standardizedFileURL.pathComponents
        let baseComponents = baseDirectory.standardizedFileURL.pathComponents
        return fileComponents.count >= baseComponents.count
            && Array(fileComponents.prefix(baseComponents.count)) == baseComponents
    }

    private static func isSymbolicLink(_ url: URL) -> Bool {
        (try? FileManager.default.destinationOfSymbolicLink(atPath: url.path)) != nil
    }

    private static func loadSkills(from directory: URL, sourceRoot: ExternalSkillRoot? = nil) -> [UUID: Skill] {
        guard
            let contents = try? FileManager.default.contentsOfDirectory(
                at: directory,
                includingPropertiesForKeys: [.isDirectoryKey],
                options: [.skipsHiddenFiles]
            )
        else {
            return [:]
        }

        var loaded: [UUID: Skill] = [:]
        for item in contents {
            var isDirectory: ObjCBool = false
            guard FileManager.default.fileExists(atPath: item.path, isDirectory: &isDirectory),
                isDirectory.boolValue,
                let skill = loadFromDirectory(item, sourceRoot: sourceRoot)
            else {
                continue
            }
            loaded[skill.id] = skill
        }
        return loaded
    }

    private static func loadFromDirectory(_ directoryURL: URL, sourceRoot: ExternalSkillRoot? = nil) -> Skill? {
        let skillMdPath = directoryURL.appendingPathComponent("SKILL.md")
        guard FileManager.default.fileExists(atPath: skillMdPath.path) else { return nil }

        do {
            let content = try String(contentsOf: skillMdPath, encoding: .utf8)
            let parsed = try Skill.parseAnyFormat(from: content)
            let resolvedDirectory = directoryURL.resolvingSymlinksInPath().standardizedFileURL
            let id =
                explicitSkillId(in: content)
                ?? sourceRoot.map {
                    deterministicExternalSkillId(
                        sourceRootId: $0.id,
                        directoryName: directoryURL.lastPathComponent,
                        name: parsed.name
                    )
                }
                ?? parsed.id

            return Skill(
                id: id,
                name: parsed.name,
                description: parsed.description,
                version: parsed.version,
                author: parsed.author,
                category: parsed.category,
                enabled: parsed.enabled,
                instructions: parsed.instructions,
                isBuiltIn: parsed.isBuiltIn,
                createdAt: parsed.createdAt,
                updatedAt: parsed.updatedAt,
                references: loadFilesFromSubdirectory(directoryURL, subdirectory: "references"),
                assets: loadFilesFromSubdirectory(directoryURL, subdirectory: "assets"),
                directoryName: directoryURL.lastPathComponent,
                pluginId: parsed.pluginId,
                sourceRootId: sourceRoot?.id,
                sourceDirectoryPath: sourceRoot == nil ? nil : resolvedDirectory.path
            )
        } catch {
            print("[Osaurus] Failed to load skill from \(directoryURL.lastPathComponent): \(error)")
            return nil
        }
    }

    private static func explicitSkillId(in content: String) -> UUID? {
        guard let split = Skill.splitFrontmatter(content) else { return nil }
        let frontmatter = Skill.parseYamlBlock(split.frontmatterLines)
        if let idString = frontmatter["id"] as? String, let id = UUID(uuidString: idString) {
            return id
        }
        if let metadata = frontmatter["metadata"] as? [String: Any],
            let idString = metadata["osaurus-id"] as? String,
            let id = UUID(uuidString: idString)
        {
            return id
        }
        return nil
    }

    private static func deterministicExternalSkillId(sourceRootId: String, directoryName: String, name: String) -> UUID {
        let seed = "external-skill:\(sourceRootId):\(directoryName):\(name)"
        let bytes = Array(SHA256.hash(data: Data(seed.utf8)))
        return UUID(
            uuid: (
                bytes[0], bytes[1], bytes[2], bytes[3],
                bytes[4], bytes[5], bytes[6], bytes[7],
                bytes[8], bytes[9], bytes[10], bytes[11],
                bytes[12], bytes[13], bytes[14], bytes[15]
            )
        )
    }

    private static func loadFilesFromSubdirectory(_ skillDir: URL, subdirectory: String) -> [SkillFile] {
        let subDir = skillDir.appendingPathComponent(subdirectory)
        return loadFiles(in: subDir, relativeTo: skillDir)
    }

    private static func loadFiles(in directory: URL, relativeTo skillDir: URL) -> [SkillFile] {
        guard
            let entries = try? FileManager.default.contentsOfDirectory(
                at: directory,
                includingPropertiesForKeys: [.fileSizeKey, .isDirectoryKey, .isRegularFileKey, .isSymbolicLinkKey],
                options: [.skipsHiddenFiles]
            )
        else {
            return []
        }

        var files: [SkillFile] = []
        for entry in entries.sorted(by: { $0.path < $1.path }) {
            guard
                let values = try? entry.resourceValues(
                    forKeys: [.fileSizeKey, .isDirectoryKey, .isRegularFileKey, .isSymbolicLinkKey]
                ),
                values.isSymbolicLink != true
            else {
                continue
            }

            if values.isDirectory == true {
                files.append(contentsOf: loadFiles(in: entry, relativeTo: skillDir))
                continue
            }

            guard values.isRegularFile == true,
                let relativePath = relativePath(for: entry, in: skillDir)
            else {
                continue
            }

            files.append(
                SkillFile(
                    name: entry.lastPathComponent,
                    relativePath: relativePath,
                    size: Int64(values.fileSize ?? 0)
                )
            )
        }
        return files
    }

    private static func relativePath(for fileURL: URL, in baseDirectory: URL) -> String? {
        let fileComponents = fileURL.standardizedFileURL.pathComponents
        let baseComponents = baseDirectory.standardizedFileURL.pathComponents
        guard fileComponents.count > baseComponents.count,
            Array(fileComponents.prefix(baseComponents.count)) == baseComponents
        else {
            return nil
        }
        return fileComponents.dropFirst(baseComponents.count).joined(separator: "/")
    }

    private static func saveBuiltInState(_ skill: Skill) {
        let dirName = ".\(skill.id.uuidString)"
        let skillDir = skillsDirectory().appendingPathComponent(dirName)

        do {
            try FileManager.default.createDirectory(at: skillDir, withIntermediateDirectories: true)
            let skillMdPath = skillDir.appendingPathComponent("SKILL.md")
            try skill.toAgentSkillsFormatWithId().write(to: skillMdPath, atomically: true, encoding: .utf8)
        } catch {
            print("[Osaurus] Failed to save built-in skill state: \(error)")
        }
    }

    private static func migrateOldFormat() {
        let directory = skillsDirectory()
        guard
            let files = try? FileManager.default.contentsOfDirectory(
                at: directory,
                includingPropertiesForKeys: nil,
                options: [.skipsHiddenFiles]
            )
        else {
            return
        }

        for file in files where file.pathExtension == "md" {
            do {
                let content = try String(contentsOf: file, encoding: .utf8)
                let skill = try Skill.parseAnyFormat(from: content)
                var dirName = skill.directoryName ?? skill.xplaceholder_agentSkillsNamex
                if dirName.isEmpty {
                    dirName = "skill-\(skill.id.uuidString.prefix(8).lowercased())"
                }
                let skillDir = directory.appendingPathComponent(dirName)

                var isDirectory: ObjCBool = false
                if FileManager.default.fileExists(atPath: skillDir.path, isDirectory: &isDirectory),
                    isDirectory.boolValue
                {
                    try? FileManager.default.removeItem(at: file)
                    continue
                }

                try FileManager.default.createDirectory(at: skillDir, withIntermediateDirectories: true)
                try skill.toAgentSkillsFormatWithId().write(
                    to: skillDir.appendingPathComponent("SKILL.md"),
                    atomically: true,
                    encoding: .utf8
                )
                try FileManager.default.removeItem(at: file)
                print("[Osaurus] Migrated skill: \(skill.name)")
            } catch {
                print("[Osaurus] Failed to migrate \(file.lastPathComponent): \(error)")
            }
        }
    }
}

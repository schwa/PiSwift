import Foundation
import PiSwiftCodingAgent

private enum PackageCommand: String {
    case install
    case remove
    case update
    case list
}

private struct PackageCommandOptions {
    var command: PackageCommand
    var source: String?
    var local: Bool
}

func handlePackageCommand(_ args: [String]) async -> Bool {
    guard let options = parsePackageCommand(args) else { return false }

    let cwd = FileManager.default.currentDirectoryPath
    let agentDir = getAgentDir()
    let settingsManager = SettingsManager.create(cwd, agentDir)
    let packageManager = DefaultPackageManager(cwd: cwd, agentDir: agentDir, settingsManager: settingsManager)

    packageManager.setProgressCallback { event in
        switch event.type {
        case "start":
            if let message = event.message {
                fputs("\(message)\n", stdout)
            }
        case "error":
            if let message = event.message {
                fputs("Error: \(message)\n", stderr)
            }
        default:
            break
        }
    }

    do {
        switch options.command {
        case .install:
            guard let source = options.source, !source.isEmpty else {
                fputs("Missing install source.\n", stderr)
                return true
            }
            try await packageManager.install(source, options: PackageResolveOptions(local: options.local))
            updatePackageSources(settingsManager, source: source, local: options.local, action: .add)
            print("Installed \(source)")
        case .remove:
            guard let source = options.source, !source.isEmpty else {
                fputs("Missing remove source.\n", stderr)
                return true
            }
            try await packageManager.remove(source, options: PackageResolveOptions(local: options.local))
            updatePackageSources(settingsManager, source: source, local: options.local, action: .remove)
            print("Removed \(source)")
        case .list:
            let globalPackages = settingsManager.getGlobalSettings().packages ?? []
            let projectPackages = settingsManager.getProjectSettings().packages ?? []
            if globalPackages.isEmpty && projectPackages.isEmpty {
                print("No packages installed.")
                return true
            }

            func formatPackage(_ pkg: PackageSource, scope: String) {
                let source = packageSourceString(pkg)
                let display = isFiltered(pkg) ? "\(source) (filtered)" : source
                print("  \(display)")
                if let path = packageManager.getInstalledPath(source, scope: scope) {
                    print("    \(path)")
                }
            }

            if !globalPackages.isEmpty {
                print("User packages:")
                for pkg in globalPackages {
                    formatPackage(pkg, scope: "user")
                }
            }

            if !projectPackages.isEmpty {
                if !globalPackages.isEmpty { print("") }
                print("Project packages:")
                for pkg in projectPackages {
                    formatPackage(pkg, scope: "project")
                }
            }
        case .update:
            try await packageManager.update(options.source)
            if let source = options.source, !source.isEmpty {
                print("Updated \(source)")
            } else {
                print("Updated packages")
            }
        }
    } catch {
        fputs("Error: \(error.localizedDescription)\n", stderr)
    }

    return true
}

private func parsePackageCommand(_ args: [String]) -> PackageCommandOptions? {
    guard let command = args.first, let parsed = PackageCommand(rawValue: command) else {
        return nil
    }

    var local = false
    var sources: [String] = []
    for arg in args.dropFirst() {
        if arg == "-l" || arg == "--local" {
            local = true
            continue
        }
        sources.append(arg)
    }

    return PackageCommandOptions(command: parsed, source: sources.first, local: local)
}

private enum PackageSourceAction {
    case add
    case remove
}

private func updatePackageSources(
    _ settingsManager: SettingsManager,
    source: String,
    local: Bool,
    action: PackageSourceAction
) {
    let currentSettings = local ? settingsManager.getProjectSettings() : settingsManager.getGlobalSettings()
    let currentPackages = currentSettings.packages ?? []

    let nextPackages: [PackageSource]
    switch action {
    case .add:
        let exists = currentPackages.contains { packageSourcesMatch($0, source) }
        nextPackages = exists ? currentPackages : currentPackages + [.simple(source)]
    case .remove:
        nextPackages = currentPackages.filter { !packageSourcesMatch($0, source) }
    }

    if local {
        settingsManager.setProjectPackages(nextPackages)
    } else {
        settingsManager.setPackages(nextPackages)
    }
}

private func packageSourceString(_ pkg: PackageSource) -> String {
    switch pkg {
    case .simple(let value):
        return value
    case .filtered(let value):
        return value.source
    }
}

private func isFiltered(_ pkg: PackageSource) -> Bool {
    if case .filtered = pkg { return true }
    return false
}

private func packageSourcesMatch(_ a: PackageSource, _ b: String) -> Bool {
    let aSource = packageSourceString(a)
    return sourcesMatch(aSource, b)
}

private func sourcesMatch(_ a: String, _ b: String) -> Bool {
    let left = normalizePackageSource(a)
    let right = normalizePackageSource(b)
    return left.type == right.type && left.key == right.key
}

private func normalizePackageSource(_ source: String) -> (type: String, key: String) {
    if source.hasPrefix("npm:") {
        let spec = source.dropFirst(4).trimmingCharacters(in: .whitespacesAndNewlines)
        let (name, _) = parseNpmSpec(String(spec))
        return ("npm", name)
    }
    if source.hasPrefix("git:") {
        let repo = source.dropFirst(4).split(separator: "@", maxSplits: 1, omittingEmptySubsequences: false).first ?? ""
        let key = String(repo)
            .replacingOccurrences(of: "https://", with: "")
            .replacingOccurrences(of: "http://", with: "")
            .replacingOccurrences(of: ".git", with: "")
        return ("git", key)
    }
    if source.hasPrefix("https://") || source.hasPrefix("http://") {
        let repo = source.split(separator: "@", maxSplits: 1, omittingEmptySubsequences: false).first ?? ""
        let key = String(repo)
            .replacingOccurrences(of: "https://", with: "")
            .replacingOccurrences(of: "http://", with: "")
            .replacingOccurrences(of: ".git", with: "")
        return ("git", key)
    }
    return ("local", source)
}

private func parseNpmSpec(_ spec: String) -> (name: String, version: String?) {
    if let atIndex = spec.lastIndex(of: "@"), atIndex != spec.startIndex {
        let name = String(spec[..<atIndex])
        let version = String(spec[spec.index(after: atIndex)...])
        if !name.isEmpty && !version.isEmpty {
            return (name, version)
        }
    }
    return (spec, nil)
}


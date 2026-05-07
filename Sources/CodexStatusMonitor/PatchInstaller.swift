import Foundation

final class PatchInstaller {
    private let locator: ExtensionLocator

    init(locator: ExtensionLocator = ExtensionLocator()) {
        self.locator = locator
    }

    func currentStatus() -> PatchStatus {
        status(using: PatchRuleRegistry())
    }

    func installOrRepair() throws -> PatchStatus {
        let registry = PatchRuleRegistry()  // reload config from disk on every install
        guard let ext = locator.latestExtension() else {
            return PatchStatus(state: .noExtensionFound)
        }
        let rules = registry.rules(for: ext.version)
        guard !rules.isEmpty else {
            throw PatchError.unsupportedVersion(ext.version.description)
        }
        for rule in rules {
            try rule.apply(to: ext)
        }
        return status(using: registry)
    }

    private func status(using registry: PatchRuleRegistry) -> PatchStatus {
        guard let ext = locator.latestExtension() else {
            return PatchStatus(state: .noExtensionFound)
        }
        let rules = registry.rules(for: ext.version)
        guard !rules.isEmpty else {
            return PatchStatus(state: .unsupported(version: ext.version.description))
        }
        do {
            let checks = try rules.map { try $0.check(extension: ext) }
            if checks.allSatisfy(\.installed) {
                return PatchStatus(state: .installed(version: ext.version.description, path: ext.root.path))
            }
            return PatchStatus(state: .notInstalled(version: ext.version.description, path: ext.root.path))
        } catch {
            return PatchStatus(state: .error(error.localizedDescription))
        }
    }
}

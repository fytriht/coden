import Foundation

struct CodexExtension: Equatable {
    let root: URL
    let version: CodexVersion

    var extensionHost: URL {
        root.appendingPathComponent("out/extension.js")
    }

    var webviewAssets: URL {
        root.appendingPathComponent("webview/assets", isDirectory: true)
    }
}

struct CodexVersion: Comparable, CustomStringConvertible, Equatable {
    let components: [Int]

    init?(_ raw: String) {
        let values = raw.split(separator: ".").map { Int($0) }
        guard values.allSatisfy({ $0 != nil }) else { return nil }
        self.components = values.map { $0 ?? 0 }
    }

    var description: String {
        components.map(String.init).joined(separator: ".")
    }

    static func < (lhs: CodexVersion, rhs: CodexVersion) -> Bool {
        let count = max(lhs.components.count, rhs.components.count)
        for index in 0..<count {
            let left = index < lhs.components.count ? lhs.components[index] : 0
            let right = index < rhs.components.count ? rhs.components[index] : 0
            if left != right { return left < right }
        }
        return false
    }
}

final class ExtensionLocator {
    private let fileManager: FileManager
    private let homeDirectory: URL

    init(fileManager: FileManager = .default, homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser) {
        self.fileManager = fileManager
        self.homeDirectory = homeDirectory
    }

    func latestExtension() -> CodexExtension? {
        findExtensions().sorted {
            if $0.version == $1.version {
                return modificationDate($0.root) > modificationDate($1.root)
            }
            return $0.version > $1.version
        }.first
    }

    func findExtensions() -> [CodexExtension] {
        let roots = [
            homeDirectory.appendingPathComponent(".vscode/extensions", isDirectory: true),
            homeDirectory.appendingPathComponent(".vscode-insiders/extensions", isDirectory: true)
        ]

        return roots.flatMap { root -> [CodexExtension] in
            guard let entries = try? fileManager.contentsOfDirectory(at: root, includingPropertiesForKeys: [.isDirectoryKey]) else {
                return []
            }
            return entries.compactMap { url in
                guard url.lastPathComponent.hasPrefix("openai.chatgpt-") else { return nil }
                guard fileManager.fileExists(atPath: url.appendingPathComponent("out/extension.js").path) else { return nil }
                guard fileManager.fileExists(atPath: url.appendingPathComponent("webview/assets").path) else { return nil }
                let packageURL = url.appendingPathComponent("package.json")
                guard
                    let data = try? Data(contentsOf: packageURL),
                    let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                    let rawVersion = object["version"] as? String,
                    let version = CodexVersion(rawVersion)
                else {
                    return nil
                }
                return CodexExtension(root: url, version: version)
            }
        }
    }

    private func modificationDate(_ url: URL) -> Date {
        ((try? url.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate) ?? .distantPast
    }
}

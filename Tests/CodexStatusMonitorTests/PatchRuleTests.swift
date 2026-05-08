import XCTest
@testable import CodexStatusMonitor

final class PatchRuleTests: XCTestCase {
    func testFixtureVersionsSelectPatchRules() throws {
        let registry = PatchRuleRegistry()
        let roots = try fixtureExtensionRoots()
        XCTAssertFalse(roots.isEmpty)

        for root in roots {
            let ext = try makeExtension(root: root)
            let rules = registry.rules(for: ext.version)
            XCTAssertFalse(rules.isEmpty, "missing rule for \(root.path)")
            for rule in rules {
                let check = try rule.check(extension: ext)
                XCTAssertTrue(check.supported, "\(rule.name) did not support \(ext.version)")
            }
        }
    }

    func testHostPatchIsIdempotentOnTemporaryCopy() throws {
        let sourceRoot = try XCTUnwrap(fixtureExtensionRoots().first)
        let tempRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("codex-status-monitor-tests-\(UUID().uuidString)", isDirectory: true)
            .appendingPathComponent("extension", isDirectory: true)
        try FileManager.default.createDirectory(at: tempRoot.deletingLastPathComponent(), withIntermediateDirectories: true)
        try FileManager.default.copyItem(at: sourceRoot, to: tempRoot)
        defer { try? FileManager.default.removeItem(at: tempRoot.deletingLastPathComponent()) }

        let ext = try makeExtension(root: tempRoot)
        let rule = HostMcpNotificationHookRule(params: PatchRuleConfig.RuleParams(
            functionEntryAnchor: nil,
            messageCaseInsertAnchor: nil,
            primaryAnchors: nil,
            fallbackAnchor: nil,
            bridgeExpression: nil
        ))

        XCTAssertFalse(try rule.check(extension: ext).installed)
        try rule.apply(to: ext)
        XCTAssertTrue(try rule.check(extension: ext).installed)
        let once = try String(contentsOf: ext.extensionHost)
        try rule.apply(to: ext)
        let twice = try String(contentsOf: ext.extensionHost)
        XCTAssertEqual(once, twice)
    }

    func testLatestFixturePatchIsIdempotentOnTemporaryCopy() throws {
        let sourceRoot = try XCTUnwrap(fixtureExtensionRoots().first {
            $0.path.contains("openai.chatgpt-26.506.21252-local")
        })
        let tempRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("codex-status-monitor-tests-\(UUID().uuidString)", isDirectory: true)
            .appendingPathComponent("extension", isDirectory: true)
        try FileManager.default.createDirectory(at: tempRoot.deletingLastPathComponent(), withIntermediateDirectories: true)
        try FileManager.default.copyItem(at: sourceRoot, to: tempRoot)
        defer { try? FileManager.default.removeItem(at: tempRoot.deletingLastPathComponent()) }

        let ext = try makeExtension(root: tempRoot)
        let rules = PatchRuleRegistry().rules(for: ext.version)
        XCTAssertFalse(rules.isEmpty)

        for rule in rules {
            try rule.apply(to: ext)
            XCTAssertTrue(try rule.check(extension: ext).installed, "\(rule.name) did not install")
        }

        let hostOnce = try String(contentsOf: ext.extensionHost)
        let webviewFiles = try FileManager.default.contentsOfDirectory(at: ext.webviewAssets, includingPropertiesForKeys: nil)
            .filter { $0.pathExtension == "js" }
            .sorted { $0.path < $1.path }
        let webviewOnce = try webviewFiles.map { try String(contentsOf: $0) }

        for rule in rules {
            try rule.apply(to: ext)
        }

        XCTAssertEqual(hostOnce, try String(contentsOf: ext.extensionHost))
        XCTAssertEqual(webviewOnce, try webviewFiles.map { try String(contentsOf: $0) })
    }

    private func fixtureExtensionRoots() throws -> [URL] {
        let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
            .appendingPathComponent("Tests/Fixtures/vsix", isDirectory: true)
        let entries = try FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: [.isDirectoryKey])
        return entries
            .filter { $0.lastPathComponent.hasPrefix("openai.chatgpt-") }
            .map { $0.appendingPathComponent("extension", isDirectory: true) }
            .sorted { $0.path < $1.path }
    }

    private func makeExtension(root: URL) throws -> CodexExtension {
        let packageURL = root.appendingPathComponent("package.json")
        let data = try Data(contentsOf: packageURL)
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        let rawVersion = try XCTUnwrap(object["version"] as? String)
        let version = try XCTUnwrap(CodexVersion(rawVersion))
        return CodexExtension(root: root, version: version)
    }
}

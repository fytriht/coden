import Foundation

// MARK: - Config types

struct PatchConfig: Codable {
    let schemaVersion: Int
    let updatedAt: String?
    let strategies: [PatchStrategy]
}

struct PatchStrategy: Codable {
    let id: String
    let versionRange: VersionRangeConfig
    let rules: [PatchRuleConfig]
}

struct VersionRangeConfig: Codable {
    let from: String?
    let to: String?

    /// Half-open interval [from, to). nil bound means unbounded.
    func contains(_ version: CodexVersion) -> Bool {
        if let f = from, let min = CodexVersion(f), version < min { return false }
        if let t = to, let max = CodexVersion(t), version >= max { return false }
        return true
    }
}

struct PatchRuleConfig: Codable {
    let type: String
    let params: RuleParams

    struct RuleParams: Codable {
        // host-mcp-notification-hook
        let functionEntryAnchor: String?
        let messageCaseInsertAnchor: String?
        // webview-pending-request
        let primaryAnchors: [String]?
        let fallbackAnchor: String?
        let bridgeExpression: String?
    }
}

// MARK: - Loader

enum PatchConfigLoader {
    static let remoteURL = "https://raw.githubusercontent.com/fytriht/coden/main/Sources/CodexStatusMonitor/Resources/patch-config.json"

    static func load() -> PatchConfig {
        if let cached = loadFrom(CodexStatusPaths.patchConfigFile) {
            return cached
        }
        if let bundled = loadBundled() {
            return bundled
        }
        return hardcodedDefault()
    }

    static func refreshInBackground() {
        guard let url = URL(string: remoteURL) else { return }
        let task = URLSession.shared.dataTask(with: url) { data, _, _ in
            guard
                let data,
                let remote = try? JSONDecoder().decode(PatchConfig.self, from: data),
                remote.schemaVersion >= 1
            else { return }
            let dest = CodexStatusPaths.patchConfigFile
            try? FileManager.default.createDirectory(at: dest.deletingLastPathComponent(), withIntermediateDirectories: true)
            try? data.write(to: dest)
        }
        task.resume()
    }

    // MARK: Private

    private static func loadFrom(_ url: URL) -> PatchConfig? {
        guard
            let data = try? Data(contentsOf: url),
            let config = try? JSONDecoder().decode(PatchConfig.self, from: data),
            config.schemaVersion >= 1
        else { return nil }
        return config
    }

    private static func loadBundled() -> PatchConfig? {
        guard
            let url = Bundle.main.url(forResource: "patch-config", withExtension: "json"),
            let config = loadFrom(url)
        else { return nil }
        return config
    }

    private static func hardcodedDefault() -> PatchConfig {
        PatchConfig(
            schemaVersion: 1,
            updatedAt: nil,
            strategies: [
                PatchStrategy(
                    id: "strategy-1",
                    versionRange: VersionRangeConfig(from: "26.406.0", to: nil),
                    rules: [
                        PatchRuleConfig(
                            type: "host-mcp-notification-hook",
                            params: PatchRuleConfig.RuleParams(
                                functionEntryAnchor: "handleMcpNotification(e){",
                                messageCaseInsertAnchor: #"case"open-in-browser":{"#,
                                primaryAnchors: nil,
                                fallbackAnchor: nil,
                                bridgeExpression: nil
                            )
                        ),
                        PatchRuleConfig(
                            type: "webview-pending-request",
                            params: PatchRuleConfig.RuleParams(
                                functionEntryAnchor: nil,
                                messageCaseInsertAnchor: nil,
                                primaryAnchors: [
                                    #"function dH(e){let t=(0,$.c)(23),{approvalQuestionActor:n,conversationId:r,hostId:i,pendingRequest:a,onSubmitLocalFollowup:o}=e;switch(a.type){"#,
                                    #"function DH(e){let t=(0,$.c)(23),{approvalQuestionActor:n,conversationId:r,hostId:i,pendingRequest:a,onSubmitLocalFollowup:o}=e;switch(a.type){"#,
                                    #"function XW(e){let t=(0,$.c)(23),{approvalQuestionActor:n,conversationId:r,hostId:i,pendingRequest:a,onSubmitLocalFollowup:o}=e;switch(a.type){"#,
                                    #"function Rq(e){let t=(0,Q.c)(23),{approvalQuestionActor:n,conversationId:r,hostId:i,pendingRequest:a,onSubmitLocalFollowup:o}=e;switch(a.type){"#,
                                    #"function Rq(e){let t=(0,Q.c)(21),{approvalQuestionActor:n,conversationId:r,hostId:i,pendingRequest:a,onSubmitLocalFollowup:o}=e;switch(a.type){"#
                                ],
                                fallbackAnchor: "if(s&&!s.isCompleted)return{type:`implementPlan`",
                                bridgeExpression: "(typeof Wo!==`undefined`?Wo:typeof q!==`undefined`?q:typeof Vf!==`undefined`?Vf:typeof li!==`undefined`?li:typeof ui!==`undefined`?ui.getInstance():null)"
                            )
                        )
                    ]
                )
            ]
        )
    }
}

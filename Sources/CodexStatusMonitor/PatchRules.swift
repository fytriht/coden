import Foundation

enum PatchError: LocalizedError {
    case unsupportedVersion(String)
    case missingHostAnchor
    case missingWebviewAnchor
    case syntaxCheckFailed(String)
    case fileReadFailed(String)
    case fileWriteFailed(String)

    var errorDescription: String? {
        switch self {
        case .unsupportedVersion(let version):
            return "Unsupported Codex VSCode extension version: \(version)"
        case .missingHostAnchor:
            return "Could not locate the stable extension host patch anchor."
        case .missingWebviewAnchor:
            return "Could not locate a supported webview pending request patch anchor."
        case .syntaxCheckFailed(let details):
            return "Patched JavaScript failed syntax check: \(details)"
        case .fileReadFailed(let path):
            return "Failed to read \(path)"
        case .fileWriteFailed(let path):
            return "Failed to write \(path)"
        }
    }
}

struct PatchCheck: Equatable {
    let supported: Bool
    let installed: Bool
    let details: [String]
}

protocol PatchRule {
    var name: String { get }
    func supports(version: CodexVersion) -> Bool
    func check(extension: CodexExtension) throws -> PatchCheck
    func apply(to extension: CodexExtension) throws
    func restore(extension: CodexExtension) throws
}

final class PatchRuleRegistry {
    private let rules: [PatchRule]

    init(rules: [PatchRule] = [DefaultHostPatchRule(), PendingRequestWebviewPatchRule()]) {
        self.rules = rules
    }

    func rules(for version: CodexVersion) -> [PatchRule] {
        rules.filter { $0.supports(version: version) }
    }

    func isSupported(version: CodexVersion) -> Bool {
        !rules(for: version).isEmpty
    }
}

struct DefaultHostPatchRule: PatchRule {
    let name = "default-host-events"

    private let anchor = #"handleMcpNotification(e){let r=this.extractConversationId(e.params);if(r)switch(e.method){case"codex/event/task_started":this.updateConversationStatus(r,2);break;case"codex/event/task_complete":this.updateConversationStatus(r,1);break;case"codex/event/turn_aborted":case"codex/event/error":case"codex/event/stream_error":this.updateConversationStatus(r,0);break;default:break}}"#
    private let marker = "__codexStatusMonitorRecord"
    private let helperVersionMarker = "__codexStatusMonitorHelperVersion=3"
    private let messageCaseMarker = #"case"codex-status-monitor-event""#

    func supports(version: CodexVersion) -> Bool {
        guard let min = CodexVersion("26.406.0"), let max = CodexVersion("26.5429.99999") else {
            return false
        }
        return version >= min && version <= max
    }

    func check(extension ext: CodexExtension) throws -> PatchCheck {
        let source = try read(ext.extensionHost)
        let installed = source.contains(marker)
            && source.contains(helperVersionMarker)
            && source.contains(#"globalThis.__codexStatusMonitorRecord(e)"#)
        let messageCaseInstalled = source.contains(messageCaseMarker)
        let supported = source.contains(anchor) || source.contains("handleMcpNotification(e){") || installed
        return PatchCheck(
            supported: supported,
            installed: installed && messageCaseInstalled,
            details: [
                installed ? "host event hook installed" : "host event hook missing",
                messageCaseInstalled ? "webview event host case installed" : "webview event host case missing"
            ]
        )
    }

    func apply(to ext: CodexExtension) throws {
        var source = try read(ext.extensionHost)
        var changed = false

        if !source.contains(helperVersionMarker) {
            source = replacingExistingHelper(in: source, version: ext.version.description)
            changed = true
        }

        if !source.contains(#"globalThis.__codexStatusMonitorRecord(e)"#) {
            let functionAnchor = "handleMcpNotification(e){"
            guard source.contains(functionAnchor) else { throw PatchError.missingHostAnchor }
            source = source.replacingOccurrences(
                of: functionAnchor,
                with: #"handleMcpNotification(e){try{globalThis.__codexStatusMonitorRecord(e)}catch{};"#,
                options: [],
                range: source.range(of: functionAnchor)
            )
            changed = true
        }

        if !source.contains(messageCaseMarker) {
            guard let openBrowserRange = source.range(of: #"case"open-in-browser":{"#) else {
                throw PatchError.missingHostAnchor
            }
            let eventCase = #"case"codex-status-monitor-event":{try{globalThis.__codexStatusMonitorRecord({method:"codex-status-monitor/pending_request",params:r})}catch{};break}"#
            source.insert(contentsOf: eventCase, at: openBrowserRange.lowerBound)
            changed = true
        }

        if changed {
            try backupIfNeeded(ext.extensionHost)
            try write(source, to: ext.extensionHost)
            try nodeCheck(ext.extensionHost)
        }
    }

    func restore(extension ext: CodexExtension) throws {
        try restoreBackup(for: ext.extensionHost)
    }

    private func helperSource(version: String) -> String {
        #";(()=>{globalThis.__codexStatusMonitorHelperVersion=3;try{const net=require("node:net"),os=require("node:os"),path=require("node:path");const sockPath=path.join(os.homedir(),"Library/Application Support/CodexStatusMonitor/events.sock");let _sock=null,_connecting=false;function _connect(){if(_connecting||(_sock&&!_sock.destroyed))return;_connecting=true;const s=net.createConnection(sockPath);s.on("connect",()=>{_sock=s;_connecting=false});s.on("error",()=>{_sock=null;_connecting=false;setTimeout(_connect,2000)});s.on("close",()=>{_sock=null;_connecting=false;setTimeout(_connect,2000)})}_connect();globalThis.__codexStatusMonitorRecord=function(e){try{const p=e&&typeof e==="object"?e.params||{}:{};const item=p.item||p;const eventType=e&&e.method?String(e.method):"unknown";const id=(...xs)=>xs.find(x=>typeof x==="string"&&x.length>0)??null;const event={schemaVersion:1,timestamp:new Date().toISOString(),extensionVersion:"\#(version)",source:"vscode-extension-host",eventType,conversationId:id(p.conversationId,p.threadId,p.id,item.conversationId,item.threadId),requestId:id(p.requestId,item.requestId,item.approvalRequestId,p.approvalRequestId,p.taskId,item.taskId),requestType:typeof p.type==="string"?p.type:typeof item.type==="string"?item.type:null,status:typeof p.status==="string"?p.status:typeof item.status==="string"?item.status:null};if(_sock&&!_sock.destroyed)_sock.write(JSON.stringify(event)+"\n")}catch{}}}catch{}})();"#
    }

    private func replacingExistingHelper(in source: String, version: String) -> String {
        let helper = helperSource(version: version)
        // Match any previously injected helper (v2 file-based or v3 socket-based)
        let startSentinels = [
            ";(()=>{globalThis.__codexStatusMonitorHelperVersion=",
            ";(()=>{if(globalThis.__codexStatusMonitorRecord",
        ]
        let endSentinel = #";"use strict";"#
        for startSentinel in startSentinels {
            guard
                let start = source.range(of: startSentinel),
                let end = source.range(of: endSentinel, range: start.upperBound..<source.endIndex)
            else { continue }
            return source.replacingCharacters(in: start.lowerBound..<end.lowerBound, with: helper)
        }
        return helper + source
    }
}

struct PendingRequestWebviewPatchRule: PatchRule {
    let name = "version-range-webview-pending-request"
    private let marker = "codex-status-monitor-event"

    func supports(version: CodexVersion) -> Bool {
        guard let min = CodexVersion("26.406.0"), let max = CodexVersion("26.5429.99999") else {
            return false
        }
        return version >= min && version <= max
    }

    func check(extension ext: CodexExtension) throws -> PatchCheck {
        guard let file = try findWebviewBundle(ext) else {
            return PatchCheck(supported: false, installed: false, details: ["webview pending request bundle not found"])
        }
        let source = try read(file)
        return PatchCheck(
            supported: true,
            installed: source.contains(marker),
            details: [source.contains(marker) ? "webview pending request hook installed" : "webview pending request hook missing"]
        )
    }

    func apply(to ext: CodexExtension) throws {
        guard let file = try findWebviewBundle(ext) else { throw PatchError.missingWebviewAnchor }
        var source = try read(file)
        guard !source.contains(marker) else { return }

        let bridge = "(typeof Wo!==`undefined`?Wo:typeof q!==`undefined`?q:typeof Vf!==`undefined`?Vf:null)"
        let injected = "try{\(bridge)?.dispatchMessage(`codex-status-monitor-event`,{conversationId:r??null,requestId:a?.item?.requestId??a?.item?.approvalRequestId??a?.requestId??null,type:a?.type??null,itemType:a?.item?.type??null})}catch{};"

        let anchors = [
            #"function DH(e){let t=(0,$.c)(23),{approvalQuestionActor:n,conversationId:r,hostId:i,pendingRequest:a,onSubmitLocalFollowup:o}=e;switch(a.type){"#,
            #"function Rq(e){let t=(0,Q.c)(23),{approvalQuestionActor:n,conversationId:r,hostId:i,pendingRequest:a,onSubmitLocalFollowup:o}=e;switch(a.type){"#,
            #"function Rq(e){let t=(0,Q.c)(21),{approvalQuestionActor:n,conversationId:r,hostId:i,pendingRequest:a,onSubmitLocalFollowup:o}=e;switch(a.type){"#
        ]

        if let anchor = anchors.first(where: { source.contains($0) }) {
            source = source.replacingOccurrences(of: "switch(a.type){", with: injected + "switch(a.type){", options: [], range: source.range(of: anchor))
        } else if source.contains("if(s&&!s.isCompleted)return{type:`implementPlan`") {
            let oldAnchor = "if(s&&!s.isCompleted)return{type:`implementPlan`"
            let oldInjected = "if(s&&!s.isCompleted)return queueMicrotask(()=>{try{\(bridge)?.dispatchMessage(`codex-status-monitor-event`,{conversationId:null,requestId:fo(s.turnId),type:`implementPlan`,itemType:null})}catch{}}),{type:`implementPlan`"
            source = source.replacingOccurrences(
                of: oldAnchor,
                with: oldInjected,
                options: [],
                range: source.range(of: oldAnchor)
            )
        } else {
            throw PatchError.missingWebviewAnchor
        }

        try backupIfNeeded(file)
        try write(source, to: file)
        try nodeCheck(file)
    }

    func restore(extension ext: CodexExtension) throws {
        guard let file = try findWebviewBundle(ext) else { return }
        try restoreBackup(for: file)
    }

    private func findWebviewBundle(_ ext: CodexExtension) throws -> URL? {
        guard let files = try? FileManager.default.contentsOfDirectory(at: ext.webviewAssets, includingPropertiesForKeys: nil) else {
            return nil
        }
        return files.first { url in
            guard url.pathExtension == "js", let source = try? String(contentsOf: url) else { return false }
            if source.contains(marker) { return true }
            let hasModernAnchor = source.contains("function DH(e)") && source.contains("pendingRequest:a") && source.contains("implementPlan")
            let hasLegacyAnchor = source.contains("function Rq(e)") && source.contains("pendingRequest:a") && source.contains("implementPlan")
            let hasDerivedPendingRequestAnchor = source.contains("if(s&&!s.isCompleted)return{type:`implementPlan`")
            return hasModernAnchor || hasLegacyAnchor || hasDerivedPendingRequestAnchor
        }
    }
}

func read(_ url: URL) throws -> String {
    guard let source = try? String(contentsOf: url, encoding: .utf8) else {
        throw PatchError.fileReadFailed(url.path)
    }
    return source
}

func write(_ source: String, to url: URL) throws {
    do {
        try source.write(to: url, atomically: true, encoding: .utf8)
    } catch {
        throw PatchError.fileWriteFailed(url.path)
    }
}

func backupIfNeeded(_ url: URL) throws {
    let backupURL = URL(fileURLWithPath: url.path + ".codex-status-monitor.bak")
    guard !FileManager.default.fileExists(atPath: backupURL.path) else { return }
    try FileManager.default.copyItem(at: url, to: backupURL)
}

func restoreBackup(for url: URL) throws {
    let backupURL = URL(fileURLWithPath: url.path + ".codex-status-monitor.bak")
    guard FileManager.default.fileExists(atPath: backupURL.path) else { return }
    _ = try FileManager.default.replaceItemAt(url, withItemAt: backupURL, backupItemName: nil, options: [])
}

func nodeCheck(_ url: URL) throws {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
    process.arguments = ["node", "--check", url.path]
    let pipe = Pipe()
    process.standardOutput = pipe
    process.standardError = pipe
    try process.run()
    process.waitUntilExit()
    guard process.terminationStatus == 0 else {
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        throw PatchError.syntaxCheckFailed(String(data: data, encoding: .utf8) ?? "unknown syntax error")
    }
}

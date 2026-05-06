import AppKit

if CommandLine.arguments.contains("--install-patch") {
    AppLogger.shared.setup(logFile: CodexStatusPaths.logFile)
    log("CLI: --install-patch")
    do {
        let status = try PatchInstaller().installOrRepair()
        log("CLI: patch result: \(status.title)")
        print(status.title)
        exit(0)
    } catch {
        logError("CLI: patch failed: \(error.localizedDescription)")
        fputs("\(error.localizedDescription)\n", stderr)
        exit(1)
    }
}

if CommandLine.arguments.contains("--patch-status") {
    AppLogger.shared.setup(logFile: CodexStatusPaths.logFile)
    log("CLI: --patch-status")
    let status = PatchInstaller().currentStatus()
    log("CLI: patch status: \(status.title)")
    print(status.title)
    exit(0)
}

let app = NSApplication.shared
app.setActivationPolicy(.accessory)

let delegate = AppDelegate()
app.delegate = delegate
app.run()

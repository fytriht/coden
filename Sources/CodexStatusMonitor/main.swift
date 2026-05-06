import AppKit

if CommandLine.arguments.contains("--install-patch") {
    do {
        let status = try PatchInstaller().installOrRepair()
        print(status.title)
        exit(0)
    } catch {
        fputs("\(error.localizedDescription)\n", stderr)
        exit(1)
    }
}

if CommandLine.arguments.contains("--patch-status") {
    let status = PatchInstaller().currentStatus()
    print(status.title)
    exit(0)
}

let app = NSApplication.shared
app.setActivationPolicy(.accessory)

let delegate = AppDelegate()
app.delegate = delegate
app.run()

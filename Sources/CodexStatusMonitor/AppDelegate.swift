import AppKit
import UserNotifications

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, UNUserNotificationCenterDelegate {
    private let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    private let store = StatusStore()
    private let patchInstaller = PatchInstaller()
    private var tailer: EventTailer?
    private var patchStatus = PatchStatus(state: .noExtensionFound)
    private var notificationStatusTitle = "Notifications: checking"
    private var pendingCompletionNotifications: [String: Task<Void, Never>] = [:]

    func applicationDidFinishLaunching(_ notification: Notification) {
        UNUserNotificationCenter.current().delegate = self
        requestNotificationAuthorization()

        store.onChange = { [weak self] in self?.refreshMenu() }
        store.onTurnCompleted = { [weak self] event in self?.scheduleTurnCompletedNotification(event) }
        store.onRunningStarted = { [weak self] conversationId in self?.cancelPendingCompletionNotification(conversationId: conversationId) }

        patchStatus = patchInstaller.currentStatus()
        preloadRecentEvents()
        startTailer()
        refreshMenu()
    }

    func applicationWillTerminate(_ notification: Notification) {
        tailer?.stop()
        pendingCompletionNotifications.values.forEach { $0.cancel() }
    }

    private func startTailer() {
        tailer = EventTailer(fileURL: CodexStatusPaths.eventsFile) { [weak self] event, isReplay in
            Task { @MainActor in
                guard let self else { return }
                let before = self.store.aggregateState
                let mapped = StatusStore.state(for: event)?.rawValue ?? "ignored"
                self.store.apply(event, notify: !isReplay)
                let after = self.store.aggregateState
                if self.shouldLog(event: event, isReplay: isReplay, mapped: mapped, before: before, after: after) {
                    self.appendLog("event replay=\(isReplay) type=\(event.eventType) conversationId=\(event.conversationId ?? "nil") requestType=\(event.requestType ?? "nil") status=\(event.status ?? "nil") mapped=\(mapped) aggregate=\(before.rawValue)->\(after.rawValue)")
                }
            }
        }
        tailer?.start()
    }

    private func shouldLog(
        event: CodexStatusEvent,
        isReplay: Bool,
        mapped: String,
        before: CodexSessionState,
        after: CodexSessionState
    ) -> Bool {
        if isReplay { return false }
        if before != after { return true }
        if mapped == CodexSessionState.waiting.rawValue { return true }
        if event.eventType == "item/completed" { return true }
        if event.eventType.hasPrefix("codex-status-monitor/") { return true }
        if event.eventType.hasPrefix("codex/event/") { return true }
        if event.eventType == "notifications/tasks/status" { return true }
        return false
    }

    private func preloadRecentEvents() {
        guard let data = try? Data(contentsOf: CodexStatusPaths.eventsFile),
              let text = String(data: data, encoding: .utf8) else {
            return
        }
        let events = text
            .split(separator: "\n")
            .suffix(20)
            .compactMap { line in
                try? JSONDecoder().decode(CodexStatusEvent.self, from: Data(line.utf8))
            }
        for event in events {
            store.recordRecent(event)
        }
    }

    private func refreshMenu() {
        statusItem.button?.title = "Codex: \(store.aggregateState.rawValue)"

        let menu = NSMenu()
        menu.addItem(disabled: patchStatus.title)
        if case .error(let detail) = patchStatus.state {
            menu.addItem(disabled: detail)
        }
        menu.addItem(disabled: notificationStatusTitle)
        menu.addItem(.separator())

        if store.sessions.isEmpty {
            menu.addItem(disabled: "Sessions: none")
        } else {
            menu.addItem(disabled: "Sessions")
            for session in store.sessions.values.sorted(by: { $0.updatedAt > $1.updatedAt }) {
                let request = session.requestType.map { " \($0)" } ?? ""
                menu.addItem(disabled: "\(session.state.rawValue) \(short(session.conversationId))\(request)")
            }
        }

        menu.addItem(.separator())
        if store.recentEvents.isEmpty {
            menu.addItem(disabled: "Recent events: none")
        } else {
            menu.addItem(disabled: "Recent events")
            for event in store.recentEvents.prefix(5) {
                menu.addItem(disabled: event.eventType.replacingOccurrences(of: "codex/event/", with: ""))
            }
        }

        menu.addItem(.separator())
        menu.addItem(action: "Install/Repair VSCode Patch", target: self, selector: #selector(installPatch))
        menu.addItem(action: "Open Notification Settings", target: self, selector: #selector(openNotificationSettings))
        menu.addItem(action: "Send Test Notification", target: self, selector: #selector(sendTestNotification))
        menu.addItem(action: "Reset Status", target: self, selector: #selector(resetStatus))
        menu.addItem(.separator())
        menu.addItem(action: "Quit", target: self, selector: #selector(quit))
        statusItem.menu = menu
    }

    @objc private func installPatch() {
        do {
            patchStatus = try patchInstaller.installOrRepair()
        } catch {
            patchStatus = PatchStatus(state: .error(error.localizedDescription))
        }
        refreshMenu()
    }

    @objc private func resetStatus() {
        store.reset()
    }

    @objc private func quit() {
        NSApplication.shared.terminate(nil)
    }

    private func scheduleTurnCompletedNotification(_ event: CodexStatusEvent) {
        let conversationId = event.conversationId ?? event.requestId ?? "unknown"
        pendingCompletionNotifications[conversationId]?.cancel()
        pendingCompletionNotifications[conversationId] = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 2_000_000_000)
            guard !Task.isCancelled else { return }
            await MainActor.run {
                guard let self else { return }
                self.pendingCompletionNotifications.removeValue(forKey: conversationId)
                self.notifyTurnCompleted(event)
            }
        }
    }

    private func cancelPendingCompletionNotification(conversationId: String) {
        pendingCompletionNotifications[conversationId]?.cancel()
        pendingCompletionNotifications.removeValue(forKey: conversationId)
    }

    private func notifyTurnCompleted(_ event: CodexStatusEvent) {
        appendLog("notify candidate eventType=\(event.eventType) conversationId=\(event.conversationId ?? "nil") requestType=\(event.requestType ?? "nil") status=\(event.status ?? "nil")")
        let content = UNMutableNotificationContent()
        content.title = "Codex"
        content.body = "Codex 任务已完成"
        content.sound = .default
        if #available(macOS 12.0, *) {
            content.interruptionLevel = .timeSensitive
        }
        let request = UNNotificationRequest(
            identifier: "codex-completed-\(event.conversationId ?? UUID().uuidString)-\(Date().timeIntervalSince1970)",
            content: content,
            trigger: nil
        )
        UNUserNotificationCenter.current().add(request) { [weak self] error in
            if error != nil {
                Task { @MainActor in
                    self?.appendLog("notification add failed: \(error?.localizedDescription ?? "unknown")")
                    self?.refreshNotificationStatus()
                }
            } else {
                Task { @MainActor in
                    self?.appendLog("notification add succeeded")
                    self?.logDeliveredNotificationsSoon()
                }
            }
        }
    }

    private func requestNotificationAuthorization() {
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { [weak self] granted, _ in
            Task { @MainActor in
                self?.notificationStatusTitle = granted ? "Notifications: enabled" : "Notifications: disabled"
                self?.appendLog("notification authorization request granted=\(granted)")
                self?.refreshNotificationStatus()
            }
        }
    }

    private func refreshNotificationStatus() {
        UNUserNotificationCenter.current().getNotificationSettings { [weak self] settings in
            let authorizationStatus = settings.authorizationStatus
            let alertSetting = settings.alertSetting
            let soundSetting = settings.soundSetting
            let notificationCenterSetting = settings.notificationCenterSetting
            let lockScreenSetting = settings.lockScreenSetting
            Task { @MainActor in
                switch authorizationStatus {
                case .authorized, .ephemeral, .provisional:
                    self?.notificationStatusTitle = "Notifications: enabled"
                case .denied:
                    self?.notificationStatusTitle = "Notifications: disabled"
                case .notDetermined:
                    self?.notificationStatusTitle = "Notifications: not requested"
                @unknown default:
                    self?.notificationStatusTitle = "Notifications: unknown"
                }
                self?.appendLog("notification settings authorization=\(authorizationStatus.rawValue) alert=\(alertSetting.rawValue) sound=\(soundSetting.rawValue) notificationCenter=\(notificationCenterSetting.rawValue) lockScreen=\(lockScreenSetting.rawValue)")
                self?.refreshMenu()
            }
        }
    }

    @objc private func openNotificationSettings() {
        let urls = [
            "x-apple.systempreferences:com.apple.Notifications-Settings.extension",
            "x-apple.systempreferences:com.apple.preference.notifications"
        ]
        for rawURL in urls {
            guard let url = URL(string: rawURL), NSWorkspace.shared.open(url) else { continue }
            return
        }
    }

    @objc private func sendTestNotification() {
        notifyTurnCompleted(CodexStatusEvent(
            schemaVersion: 1,
            timestamp: ISO8601DateFormatter.codexStatusFormatter().string(from: Date()),
            extensionVersion: nil,
            source: "app",
            eventType: "test-notification",
            conversationId: nil,
            requestId: nil,
            requestType: nil,
            status: nil
        ))
    }

    private func appendLog(_ message: String) {
        let directory = CodexStatusPaths.appSupportDirectory
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let line = "\(ISO8601DateFormatter.codexStatusFormatter().string(from: Date())) \(message)\n"
        let url = directory.appendingPathComponent("app.log")
        if let data = line.data(using: .utf8) {
            if FileManager.default.fileExists(atPath: url.path), let handle = try? FileHandle(forWritingTo: url) {
                _ = try? handle.seekToEnd()
                try? handle.write(contentsOf: data)
                try? handle.close()
            } else {
                try? data.write(to: url)
            }
        }
    }

    private func logDeliveredNotificationsSoon() {
        Task {
            try? await Task.sleep(nanoseconds: 1_000_000_000)
            let notifications = await UNUserNotificationCenter.current().deliveredNotifications()
            let ids = notifications.map(\.request.identifier).joined(separator: ",")
            let count = notifications.count
            await MainActor.run { [weak self] in
                self?.appendLog("delivered notifications count=\(count) ids=\(ids)")
            }
        }
    }
    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification,
        withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void
    ) {
        completionHandler([.banner, .sound])
    }

    private func short(_ id: String) -> String {
        id.count > 10 ? String(id.prefix(10)) : id
    }
}

private extension NSMenu {
    func addItem(disabled title: String) {
        let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        item.isEnabled = false
        addItem(item)
    }

    func addItem(action title: String, target: AnyObject, selector: Selector) {
        let item = NSMenuItem(title: title, action: selector, keyEquivalent: "")
        item.target = target
        addItem(item)
    }
}

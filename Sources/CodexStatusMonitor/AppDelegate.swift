import AppKit
import UserNotifications

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, UNUserNotificationCenterDelegate {
    private let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    private let store = StatusStore()
    private let patchInstaller = PatchInstaller()
    private var socketServer: EventSocketServer?
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
        startSocketServer()
        refreshMenu()
    }

    func applicationWillTerminate(_ notification: Notification) {
        socketServer?.stop()
        pendingCompletionNotifications.values.forEach { $0.cancel() }
    }

    private func startSocketServer() {
        socketServer = EventSocketServer(socketURL: CodexStatusPaths.socketFile) { [weak self] event in
            Task { @MainActor in
                guard let self else { return }
                self.store.apply(event, notify: true)
            }
        }
        socketServer?.start()
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
                    self?.refreshNotificationStatus()
                }
            }
        }
    }

    private func requestNotificationAuthorization() {
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { [weak self] granted, _ in
            Task { @MainActor in
                self?.notificationStatusTitle = granted ? "Notifications: enabled" : "Notifications: disabled"
                self?.refreshNotificationStatus()
            }
        }
    }

    private func refreshNotificationStatus() {
        UNUserNotificationCenter.current().getNotificationSettings { [weak self] settings in
            let authorizationStatus = settings.authorizationStatus
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

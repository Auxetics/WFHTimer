import Cocoa
import ServiceManagement
import UserNotifications

enum UpdateState {
    case upToDate
    case downloading
    case updateReady(dmgURL: URL)
}

enum AppMode: String {
    case stopwatch
    case pomodoro
}

enum PomodoroSession {
    case work
    case `break`
}

private struct GitHubRelease: Decodable {
    struct Asset: Decodable {
        let name: String
        let browser_download_url: String
    }
    let tag_name: String
    let assets: [Asset]
}

class AutoUpdater: NSObject {
    private static let allowedDownloadPrefix = "https://github.com/auxetics/wfhtimer/releases/download/"
    var currentState: UpdateState = .upToDate
    var currentVersion: String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.7"
    }
    
    func checkForUpdates() {
        guard let url = URL(string: "https://api.github.com/repos/Auxetics/WFHTimer/releases/latest") else { return }
        var request = URLRequest(url: url)
        request.setValue("WFHTimer-Updater", forHTTPHeaderField: "User-Agent")
        
        URLSession.shared.dataTask(with: request) { data, _, error in
            guard let data = data, error == nil,
                  let release = try? JSONDecoder().decode(GitHubRelease.self, from: data) else { return }
            
            let version = release.tag_name.replacingOccurrences(of: "v", with: "")
            guard version.compare(self.currentVersion, options: .numeric) == .orderedDescending,
                  let dmgAsset = release.assets.first(where: { $0.name.lowercased().hasSuffix(".dmg") }),
                  dmgAsset.browser_download_url.lowercased().hasPrefix(Self.allowedDownloadPrefix),
                  let downloadURL = URL(string: dmgAsset.browser_download_url) else { return }
            
            self.downloadUpdate(url: downloadURL)
        }.resume()
    }
    
    func downloadUpdate(url: URL) {
        DispatchQueue.main.async { self.currentState = .downloading }
        
        URLSession.shared.downloadTask(with: url) { localURL, _, error in
            guard let localURL = localURL, error == nil else {
                DispatchQueue.main.async { self.currentState = .upToDate }
                return
            }
            let destinationURL = FileManager.default.temporaryDirectory
                .appendingPathComponent("WFHTimer_Update_\(UUID().uuidString).dmg")
            do {
                try FileManager.default.moveItem(at: localURL, to: destinationURL)
                DispatchQueue.main.async {
                    self.currentState = .updateReady(dmgURL: destinationURL)
                }
            } catch {
                print("Failed to save update DMG: \(error)")
                DispatchQueue.main.async { self.currentState = .upToDate }
            }
        }.resume()
    }
    
    func applyUpdate(dmgURL: URL) {
        let mountPoint = "/Volumes/WFHTimerUpdate_\(ProcessInfo.processInfo.processIdentifier)"
        let script = """
        sleep 2
        hdiutil attach "$1" -nobrowse -mountpoint "$2"
        rm -rf "/Applications/WFHTimer.app"
        cp -R "$2/WFHTimer.app" "/Applications/"
        hdiutil detach "$2" -force
        rm -f "$1"
        open "/Applications/WFHTimer.app"
        """
        
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/nohup")
        process.arguments = ["/bin/bash", "-c", script, "_", dmgURL.path, mountPoint]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        do {
            try process.run()
            NSApp.terminate(nil)
        } catch {
            print("Failed to run update script: \(error)")
        }
    }
}

class AppDelegate: NSObject, NSApplicationDelegate, UNUserNotificationCenterDelegate {
    var statusItem: NSStatusItem!
    
    var timer: Timer?
    var startTime: Date?
    var accumulatedTime: TimeInterval = 0
    var isRunning = false
    var mode: AppMode = .stopwatch {
        didSet { UserDefaults.standard.set(mode.rawValue, forKey: "appMode") }
    }
    var pomodoroSession: PomodoroSession = .work
    var pomodoroRemainingSeconds: TimeInterval = 0
    
    var lastClickTime: Date?
    let updater = AutoUpdater()
    
    var workDuration: Int {
        get { max(1, UserDefaults.standard.integer(forKey: "workDuration")) }
        set { UserDefaults.standard.set(newValue, forKey: "workDuration") }
    }
    
    var breakDuration: Int {
        get { max(1, UserDefaults.standard.integer(forKey: "breakDuration")) }
        set { UserDefaults.standard.set(newValue, forKey: "breakDuration") }
    }
    
    var currentSessionDuration: TimeInterval {
        TimeInterval((pomodoroSession == .work ? workDuration : breakDuration) * 60)
    }
    
    var hasActiveTimer: Bool {
        isRunning || (mode == .stopwatch ? accumulatedTime > 0 : pomodoroRemainingSeconds < currentSessionDuration)
    }
    
    func applicationDidFinishLaunching(_ aNotification: Notification) {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        
        if let button = statusItem.button {
            button.action = #selector(handleClick)
            button.target = self
            button.sendAction(on: [.leftMouseDown, .rightMouseDown])
        }
        
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { _, _ in }
        UNUserNotificationCenter.current().delegate = self
        
        UserDefaults.standard.register(defaults: [
            "workDuration": 25,
            "breakDuration": 5,
            "appMode": AppMode.stopwatch.rawValue
        ])
        if let savedMode = UserDefaults.standard.string(forKey: "appMode"),
           let restoredMode = AppMode(rawValue: savedMode) {
            mode = restoredMode
        }
        
        reset()
        updater.checkForUpdates()
    }
    
    func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification, withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void) {
        completionHandler([.banner, .sound])
    }
    
    @objc func handleClick() {
        guard let currentEvent = NSApp.currentEvent else { return }
        
        if currentEvent.type == .rightMouseDown {
            showMenu(event: currentEvent)
            return
        }
        
        let now = Date()
        if let lastClick = lastClickTime, now.timeIntervalSince(lastClick) < 0.35 {
            lastClickTime = nil
            reset()
        } else {
            lastClickTime = now
            isRunning ? pause() : start()
        }
    }
    
    func start() {
        if isRunning { return }
        isRunning = true
        startTime = Date()
        
        updateTime()
        timer = Timer.scheduledTimer(timeInterval: 1.0, target: self, selector: #selector(updateTime), userInfo: nil, repeats: true)
        RunLoop.current.add(timer!, forMode: .common)
    }
    
    func pause() {
        if !isRunning { return }
        isRunning = false
        if let start = startTime {
            if mode == .stopwatch {
                accumulatedTime += Date().timeIntervalSince(start)
            } else {
                pomodoroRemainingSeconds -= Date().timeIntervalSince(start)
            }
        }
        startTime = nil
        timer?.invalidate()
        timer = nil
        updateTime()
    }
    
    func reset() {
        isRunning = false
        timer?.invalidate()
        timer = nil
        accumulatedTime = 0
        startTime = nil
        
        if mode == .pomodoro {
            pomodoroSession = .work
            pomodoroRemainingSeconds = currentSessionDuration
        }
        
        updateTime()
    }
    
    @objc func updateTime() {
        if mode == .stopwatch {
            var elapsed = accumulatedTime
            if let start = startTime, isRunning {
                elapsed += Date().timeIntervalSince(start)
            }
            updateDisplay(seconds: Int(elapsed))
        } else {
            var remaining = pomodoroRemainingSeconds
            if let start = startTime, isRunning {
                remaining -= Date().timeIntervalSince(start)
            }
            
            if remaining <= 0 && isRunning {
                handlePomodoroEnd()
                return
            }
            updateDisplay(seconds: Int(max(0, remaining)))
        }
    }
    
    func sendRobustNotification(title: String, body: String) {
        UNUserNotificationCenter.current().getNotificationSettings { settings in
            if settings.authorizationStatus == .authorized || settings.authorizationStatus == .provisional {
                let content = UNMutableNotificationContent()
                content.title = title
                content.body = body
                content.sound = .default
                let request = UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil)
                UNUserNotificationCenter.current().add(request)
            } else {
                DispatchQueue.main.async {
                    let safeTitle = title.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"")
                    let safeBody = body.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"")
                    let script = "display notification \"\(safeBody)\" with title \"\(safeTitle)\" sound name \"Glass\""
                    var error: NSDictionary?
                    NSAppleScript(source: script)?.executeAndReturnError(&error)
                }
            }
        }
    }
    
    func handlePomodoroEnd() {
        isRunning = false
        timer?.invalidate()
        timer = nil
        startTime = nil
        
        if pomodoroSession == .work {
            pomodoroSession = .break
            pomodoroRemainingSeconds = currentSessionDuration
            sendRobustNotification(title: "Work Session Complete!", body: "Time for a break.")
        } else {
            pomodoroSession = .work
            pomodoroRemainingSeconds = currentSessionDuration
            sendRobustNotification(title: "Break Over!", body: "Back to work.")
        }
        
        start()
    }
    
    func updateDisplay(seconds totalSeconds: Int) {
        let hours = totalSeconds / 3600
        let minutes = (totalSeconds % 3600) / 60
        let secs = totalSeconds % 60
        
        let timeString = hours >= 1
            ? String(format: "%02d:%02d:%02d", hours, minutes, secs)
            : String(format: "%02d:%02d", minutes, secs)
        
        guard let button = statusItem.button else { return }
        let font = NSFont.monospacedDigitSystemFont(ofSize: NSFont.systemFontSize, weight: .regular)
        let textColor: NSColor = (mode == .pomodoro && pomodoroSession == .break) ? .systemOrange : .labelColor
        
        let finalString = NSMutableAttributedString()
        if hasActiveTimer {
            let dotColor: NSColor = isRunning ? .systemGreen : .systemOrange
            finalString.append(NSAttributedString(string: "● ", attributes: [.font: font, .foregroundColor: dotColor]))
        }
        finalString.append(NSAttributedString(string: timeString, attributes: [.font: font, .foregroundColor: textColor]))
        button.attributedTitle = finalString
    }
    
    func showMenu(event: NSEvent) {
        let menu = NSMenu()
        
        let modeItem = NSMenuItem(title: mode == .stopwatch ? "Switch to Pomodoro Mode" : "Switch to Stopwatch Mode", action: #selector(toggleMode), keyEquivalent: "")
        modeItem.target = self
        menu.addItem(modeItem)
        
        if mode == .pomodoro {
            let skipTitle = pomodoroSession == .work ? "Skip to Break" : "Skip to Work"
            let skipItem = NSMenuItem(title: skipTitle, action: #selector(skipPhase), keyEquivalent: "")
            skipItem.target = self
            menu.addItem(skipItem)
        }
        
        let prefsItem = NSMenuItem(title: "Preferences...", action: #selector(openPreferences), keyEquivalent: ",")
        prefsItem.target = self
        menu.addItem(prefsItem)
        
        menu.addItem(.separator())
        
        let updateItem = NSMenuItem()
        updateItem.target = self
        switch updater.currentState {
        case .upToDate:
            updateItem.title = "Up to Date (v\(updater.currentVersion))"
            updateItem.action = #selector(checkUpdatesManually)
        case .downloading:
            updateItem.title = "Downloading Update..."
            updateItem.action = nil
        case .updateReady:
            updateItem.title = "Update Now!"
            updateItem.action = #selector(performUpdate)
        }
        menu.addItem(updateItem)
        menu.addItem(.separator())
        
        let autorunItem = NSMenuItem(title: "Launch on Startup", action: #selector(toggleAutorun), keyEquivalent: "")
        autorunItem.target = self
        autorunItem.state = SMAppService.mainApp.status == .enabled ? .on : .off
        menu.addItem(autorunItem)
        
        menu.addItem(.separator())
        
        let donateItem = NSMenuItem(title: "Donate", action: #selector(openDonate), keyEquivalent: "")
        donateItem.target = self
        menu.addItem(donateItem)
        
        menu.addItem(.separator())
        
        let quitItem = NSMenuItem(title: "Quit WFHTimer", action: #selector(quitApp), keyEquivalent: "q")
        quitItem.target = self
        menu.addItem(quitItem)
        
        if let button = statusItem.button {
            NSMenu.popUpContextMenu(menu, with: event, for: button)
        }
    }
    
    @objc func toggleMode() {
        mode = (mode == .stopwatch) ? .pomodoro : .stopwatch
        reset()
    }
    
    @objc func skipPhase() {
        let wasRunning = isRunning
        isRunning = false
        timer?.invalidate()
        timer = nil
        startTime = nil
        
        pomodoroSession = (pomodoroSession == .work) ? .break : .work
        pomodoroRemainingSeconds = currentSessionDuration
        
        if wasRunning {
            start()
        } else {
            updateTime()
        }
    }
    
    @objc func openPreferences() {
        let alert = NSAlert()
        alert.messageText = "Pomodoro Preferences"
        alert.informativeText = "Set your Work and Break durations (in minutes):"
        
        let view = NSView(frame: NSRect(x: 0, y: 0, width: 200, height: 60))
        
        let workLabel = NSTextField(labelWithString: "Work:")
        workLabel.frame = NSRect(x: 0, y: 35, width: 60, height: 20)
        view.addSubview(workLabel)
        
        let workInput = NSTextField(frame: NSRect(x: 60, y: 35, width: 140, height: 20))
        workInput.stringValue = String(workDuration)
        view.addSubview(workInput)
        
        let breakLabel = NSTextField(labelWithString: "Break:")
        breakLabel.frame = NSRect(x: 0, y: 5, width: 60, height: 20)
        view.addSubview(breakLabel)
        
        let breakInput = NSTextField(frame: NSRect(x: 60, y: 5, width: 140, height: 20))
        breakInput.stringValue = String(breakDuration)
        view.addSubview(breakInput)
        
        alert.accessoryView = view
        alert.addButton(withTitle: "Save")
        alert.addButton(withTitle: "Cancel")
        
        NSApp.activate(ignoringOtherApps: true)
        
        if alert.runModal() == .alertFirstButtonReturn {
            if let w = Int(workInput.stringValue), w > 0 { workDuration = w }
            if let b = Int(breakInput.stringValue), b > 0 { breakDuration = b }
            if mode == .pomodoro && !isRunning {
                reset()
            }
        }
    }
    
    @objc func checkUpdatesManually() {
        updater.checkForUpdates()
    }
    
    @objc func performUpdate() {
        if hasActiveTimer {
            let alert = NSAlert()
            alert.messageText = "Cannot Update"
            alert.informativeText = "Please reset the timer before applying an update to prevent losing your tracked time."
            alert.alertStyle = .warning
            alert.addButton(withTitle: "OK")
            NSApp.activate(ignoringOtherApps: true)
            alert.runModal()
            return
        }
        
        if case .updateReady(let url) = updater.currentState {
            updater.applyUpdate(dmgURL: url)
        }
    }
    
    @objc func toggleAutorun() {
        do {
            if SMAppService.mainApp.status == .enabled {
                try SMAppService.mainApp.unregister()
            } else {
                try SMAppService.mainApp.register()
            }
        } catch {
            print("Failed to toggle autorun: \(error)")
        }
    }
    
    @objc func openDonate() {
        if let url = URL(string: "https://ko-fi.com/auxetics") {
            NSWorkspace.shared.open(url)
        }
    }
    
    @objc func quitApp() {
        NSApp.terminate(nil)
    }
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.accessory)
app.run()

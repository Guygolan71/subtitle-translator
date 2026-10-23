// Subtitle Translator — a macOS menu-bar app that watches a folder for English
// .srt subtitle files and translates them to Hebrew with Claude.

import Cocoa
import UserNotifications
import ServiceManagement
import UniformTypeIdentifiers

let appTitle = "מתרגם כתוביות"

// MARK: - Settings

enum Models {
    static let quality = "claude-sonnet-5-5"
    static let fast = "claude-haiku-5-5"
}

enum Settings {
    static var d: UserDefaults { UserDefaults.standard }

    static var folderURL: URL {
        get {
            if let p = d.string(forKey: "watchFolder") { return URL(fileURLWithPath: p, isDirectory: true) }
            return FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask).first
                ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Downloads")
        }
        set { d.set(newValue.path, forKey: "watchFolder") }
    }

    /// Files older than this moment are ignored by the watcher (so choosing a
    /// folder doesn't translate everything that was already sitting in it).
    static var baseline: Date {
        get { d.object(forKey: "baseline") as? Date ?? Date.distantPast }
        set { d.set(newValue, forKey: "baseline") }
    }

    static var model: String {
        get { d.string(forKey: "model") ?? Models.quality }
        set { d.set(newValue, forKey: "model") }
    }

    static var rtlFix: Bool {
        get { d.object(forKey: "rtlFix") as? Bool ?? true }
        set { d.set(newValue, forKey: "rtlFix") }
    }

    static var didFirstRun: Bool {
        get { d.bool(forKey: "didFirstRun") }
        set { d.set(newValue, forKey: "didFirstRun") }
    }
}

// MARK: - API key storage (a private file in Application Support, mode 600)

enum KeyStore {
    static var fileURL: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Library/Application Support")
        let dir = base.appendingPathComponent("SubtitleTranslator", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true,
                                                 attributes: [.posixPermissions: 0o700])
        return dir.appendingPathComponent("api-key")
    }

    static func load() -> String? {
        guard let s = try? String(contentsOf: fileURL, encoding: .utf8) else { return nil }
        let t = s.trimmingCharacters(in: .whitespacesAndNewlines)
        return t.isEmpty ? nil : t
    }

    static func save(_ key: String) throws {
        try key.write(to: fileURL, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: fileURL.path)
    }
}

// MARK: - SRT handling

struct Cue {
    var index: String
    var timing: String
    var text: String
}

enum SRT {
    static func decode(_ data: Data) -> String? {
        if data.starts(with: [0xFF, 0xFE]) || data.starts(with: [0xFE, 0xFF]) {
            return String(data: data, encoding: .utf16)
        }
        var d = data
        if d.starts(with: [0xEF, 0xBB, 0xBF]) { d = Data(d.dropFirst(3)) }
        if let s = String(data: d, encoding: .utf8) { return s }
        return String(data: d, encoding: .windowsCP1252) ?? String(data: d, encoding: .isoLatin1)
    }

    static func parse(_ raw: String) -> [Cue] {
        var text = raw
        if text.hasPrefix("\u{FEFF}") { text.removeFirst() }
        text = text.replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\r", with: "\n")

        var blocks: [[String]] = []
        var cur: [String] = []
        for line in text.components(separatedBy: "\n") {
            if line.trimmingCharacters(in: .whitespaces).isEmpty {
                if !cur.isEmpty { blocks.append(cur); cur = [] }
            } else {
                cur.append(line)
            }
        }
        if !cur.isEmpty { blocks.append(cur) }

        var cues: [Cue] = []
        for b in blocks {
            guard let t = b.firstIndex(where: { $0.contains("-->") }) else {
                // Stray text (e.g. a blank line inside a cue) — keep it with the previous cue.
                if !cues.isEmpty { cues[cues.count - 1].text += "\n" + b.joined(separator: "\n") }
                continue
            }
            let idx = t > 0 ? b[t - 1].trimmingCharacters(in: .whitespaces) : String(cues.count + 1)
            let body = b[(t + 1)...].joined(separator: "\n")
            cues.append(Cue(index: idx, timing: b[t].trimmingCharacters(in: .whitespaces), text: body))
        }
        return cues
    }

    static func serialize(_ cues: [Cue]) -> String {
        var parts: [String] = []
        for (i, c) in cues.enumerated() {
            let body = c.text.replacingOccurrences(of: "\n", with: "\r\n")
            parts.append("\(i + 1)\r\n\(c.timing)\r\n\(body)")
        }
        return parts.joined(separator: "\r\n\r\n") + "\r\n"
    }

    static func looksHebrew(_ s: String) -> Bool {
        var heb = 0, lat = 0
        for u in s.unicodeScalars {
            let v = u.value
            if v >= 0x0590 && v <= 0x05FF { heb += 1 }
            else if (v >= 65 && v <= 90) || (v >= 97 && v <= 122) { lat += 1 }
        }
        return heb > lat
    }

    /// Wraps each line in RIGHT-TO-LEFT MARKs so players and TVs without proper
    /// bidi support show punctuation (. , ? ! -) on the correct side.
    static func rtlFix(_ text: String) -> String {
        let rlm = "\u{200F}"
        return text.components(separatedBy: "\n").map { line -> String in
            let clean = line.replacingOccurrences(of: rlm, with: "")
            if clean.trimmingCharacters(in: .whitespaces).isEmpty { return clean }
            // Keep a leading {\an8}-style tag at the very start of the line.
            if clean.hasPrefix("{"), let close = clean.firstIndex(of: "}") {
                let tag = String(clean[...close])
                let rest = String(clean[clean.index(after: close)...])
                return tag + rlm + rest + rlm
            }
            return rlm + clean + rlm
        }.joined(separator: "\n")
    }

    static func isSourceCandidate(_ u: URL) -> Bool {
        guard u.pathExtension.lowercased() == "srt" else { return false }
        let stem = u.deletingPathExtension().lastPathComponent.lowercased()
        for suf in [".he", ".heb", ".hebrew", ".iw", "_he", "-he"] where stem.hasSuffix(suf) { return false }
        return true
    }

    static func outputURL(for u: URL) -> URL {
        var stem = u.deletingPathExtension().lastPathComponent
        for suf in [".en", ".eng", ".english"] where stem.lowercased().hasSuffix(suf) {
            stem = String(stem.dropLast(suf.count))
            break
        }
        return u.deletingLastPathComponent().appendingPathComponent(stem + ".he.srt")
    }
}

// MARK: - Claude translation

struct APIError: LocalizedError {
    let message: String
    let fatal: Bool
    var errorDescription: String? { message }
}

final class Translator {
    let apiKey: String
    let model: String
    let batchSize = 40
    let parallel = 4

    init(apiKey: String, model: String) {
        self.apiKey = apiKey
        self.model = model
    }

    static let systemPrompt = """
    You are a professional Israeli subtitle translator. You translate English movie and TV subtitles \
    into natural, fluent, idiomatic Hebrew, the way a skilled native subtitler would for Israeli \
    viewers.

    Rules:
    - Translate the meaning and tone, not word by word. Use natural spoken Hebrew for dialogue, \
    including slang where the English uses slang.
    - Keep it short and readable: subtitles are read quickly. Condense when natural.
    - Keep the line structure: if an item has two lines (separated by \\n), return two lines; never \
    more than two lines per item.
    - Use the surrounding items to get gender, plurality and context right.
    - Keep formatting tags exactly as they are: <i> </i> <b> </b> <u> </u> <font ...> </font> and \
    tags like {\\an8}.
    - Keep a leading "- " for dialogue lines.
    - Do not translate people's names; write them in Hebrew letters as Israelis would.
    - Sound descriptions like [door slams] become [דלת נטרקת].
    - Do not add explanations, notes or nikud.

    Output format: ONLY a JSON array, with one object per input item, in the same order: \
    [{"i": <same number as input>, "t": "<Hebrew text>"}]. No text before or after the JSON.
    """

    func translate(_ cues: [Cue], progress: @escaping (Double) -> Void) async throws -> [String] {
        let batches: [Range<Int>] = stride(from: 0, to: cues.count, by: batchSize).map {
            $0..<min($0 + batchSize, cues.count)
        }
        var results = [String](repeating: "", count: cues.count)
        var done = 0

        try await withThrowingTaskGroup(of: (Range<Int>, [String]).self) { group in
            var next = 0
            while next < min(parallel, batches.count) {
                let r = batches[next]
                next += 1
                group.addTask { (r, try await self.translateBatch(cues, r)) }
            }
            while let item = try await group.next() {
                let (r, texts) = item
                for (k, i) in r.enumerated() { results[i] = texts[k] }
                done += 1
                progress(Double(done) / Double(batches.count))
                if next < batches.count {
                    let r2 = batches[next]
                    next += 1
                    group.addTask { (r2, try await self.translateBatch(cues, r2)) }
                }
            }
        }
        return results
    }

    func translateBatch(_ cues: [Cue], _ r: Range<Int>) async throws -> [String] {
        let ctxStart = max(0, r.lowerBound - 5)
        let context = cues[ctxStart..<r.lowerBound].map { $0.text }.joined(separator: "\n")
        let items: [[String: Any]] = r.map { ["i": $0 - r.lowerBound, "t": cues[$0].text] }
        let itemsData = try JSONSerialization.data(withJSONObject: items, options: [])
        let itemsJSON = String(data: itemsData, encoding: .utf8) ?? "[]"

        var prompt = ""
        if !context.isEmpty {
            prompt += "Previous lines, for context only (do not translate them):\n\(context)\n\n"
        }
        prompt += "Translate these \(r.count) subtitle items to Hebrew:\n\(itemsJSON)"

        var lastError: Error = APIError(message: "שגיאה לא ידועה", fatal: false)
        for attempt in 0..<5 {
            do {
                let text = try await call(prompt)
                if let parsed = Translator.parseItems(text, count: r.count) {
                    return r.enumerated().map { (k, i) in parsed[k] ?? cues[i].text }
                }
                lastError = APIError(message: "התקבלה תשובה לא תקינה מהמודל", fatal: false)
            } catch let e as APIError where e.fatal {
                throw e
            } catch {
                lastError = error
            }
            let delay = UInt64(pow(2.0, Double(attempt)) * 2_000_000_000)
            try await Task.sleep(nanoseconds: delay)
        }
        throw lastError
    }

    static func parseItems(_ text: String, count: Int) -> [String?]? {
        guard let s = text.firstIndex(of: "["), let e = text.lastIndex(of: "]"), s < e else { return nil }
        let json = String(text[s...e])
        guard let data = json.data(using: .utf8),
              let arr = (try? JSONSerialization.jsonObject(with: data, options: [])) as? [[String: Any]]
        else { return nil }
        var out = [String?](repeating: nil, count: count)
        for o in arr {
            var idx: Int?
            if let i = o["i"] as? Int { idx = i } else if let i = o["i"] as? String { idx = Int(i) }
            if let i = idx, i >= 0, i < count, let t = o["t"] as? String { out[i] = t }
        }
        let missing = out.filter { $0 == nil }.count
        if missing > max(1, count / 10) { return nil }
        return out
    }

    func call(_ prompt: String) async throws -> String {
        guard let url = URL(string: "https://api.anthropic.com/v1/messages") else {
            throw APIError(message: "כתובת לא תקינה", fatal: true)
        }
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.timeoutInterval = 240
        req.setValue(apiKey, forHTTPHeaderField: "x-api-key")
        req.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
        req.setValue("application/json", forHTTPHeaderField: "content-type")
        let body: [String: Any] = [
            "model": model,
            "max_tokens": 8192,
            "system": Translator.systemPrompt,
            "messages": [["role": "user", "content": prompt]],
        ]
        req.httpBody = try JSONSerialization.data(withJSONObject: body, options: [])

        let (data, resp) = try await URLSession.shared.data(for: req)
        let code = (resp as? HTTPURLResponse)?.statusCode ?? 0
        let json = (try? JSONSerialization.jsonObject(with: data, options: [])) as? [String: Any]

        if code != 200 {
            let errObj = json?["error"] as? [String: Any]
            let msg = (errObj?["message"] as? String) ?? "HTTP \(code)"
            switch code {
            case 401:
                throw APIError(message: "מפתח ה-API לא תקין", fatal: true)
            case 403:
                throw APIError(message: "אין הרשאה: \(msg)", fatal: true)
            case 400 where msg.lowercased().contains("credit"):
                throw APIError(message: "נגמר הקרדיט בחשבון Anthropic", fatal: true)
            case 400, 404:
                throw APIError(message: msg, fatal: true)
            default:
                throw APIError(message: msg, fatal: false)
            }
        }

        var out = ""
        for block in (json?["content"] as? [[String: Any]]) ?? [] {
            if (block["type"] as? String) == "text", let t = block["text"] as? String { out += t }
        }
        return out
    }

    static func validate(_ key: String) async -> Bool {
        guard let url = URL(string: "https://api.anthropic.com/v1/models") else { return false }
        var req = URLRequest(url: url)
        req.timeoutInterval = 30
        req.setValue(key, forHTTPHeaderField: "x-api-key")
        req.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
        guard let (_, resp) = try? await URLSession.shared.data(for: req) else { return false }
        return (resp as? HTTPURLResponse)?.statusCode == 200
    }
}

// MARK: - One translation job

enum JobError: LocalizedError {
    case unreadable, empty, alreadyHebrew
    var errorDescription: String? {
        switch self {
        case .unreadable: return "לא הצלחתי לקרוא את הקובץ"
        case .empty: return "לא נמצאו כתוביות בקובץ"
        case .alreadyHebrew: return "הקובץ כבר בעברית"
        }
    }
}

enum Job {
    static func run(_ u: URL, key: String, model: String, rtl: Bool,
                    progress: @escaping (Double) -> Void) async throws -> URL {
        let data = try Data(contentsOf: u)
        guard let text = SRT.decode(data) else { throw JobError.unreadable }
        var cues = SRT.parse(text)
        guard !cues.isEmpty else { throw JobError.empty }
        if SRT.looksHebrew(text) { throw JobError.alreadyHebrew }

        let translator = Translator(apiKey: key, model: model)
        let translated = try await translator.translate(cues, progress: progress)
        for i in cues.indices {
            var t = translated[i].isEmpty ? cues[i].text : translated[i]
            if rtl { t = SRT.rtlFix(t) }
            cues[i].text = t
        }

        let outURL = SRT.outputURL(for: u)
        var bytes = Data([0xEF, 0xBB, 0xBF])
        bytes.append(Data(SRT.serialize(cues).utf8))
        try bytes.write(to: outURL, options: .atomic)
        return outURL
    }
}

// MARK: - Notifications

enum Notifier {
    static func send(_ title: String, _ body: String, path: String? = nil) {
        let center = UNUserNotificationCenter.current()
        center.getNotificationSettings { s in
            if s.authorizationStatus == .authorized || s.authorizationStatus == .provisional {
                let c = UNMutableNotificationContent()
                c.title = title
                c.body = body
                c.sound = .default
                if let p = path { c.userInfo = ["path": p] }
                center.add(UNNotificationRequest(identifier: UUID().uuidString, content: c, trigger: nil))
            } else {
                osascript(title, body)
            }
        }
    }

    /// Fallback that always works, even if notification permission was not granted.
    static func osascript(_ title: String, _ body: String) {
        func esc(_ s: String) -> String {
            s.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"")
        }
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        p.arguments = ["-e", "display notification \"\(esc(body))\" with title \"\(esc(title))\" sound name \"Glass\""]
        try? p.run()
    }
}

// MARK: - Folder watcher

final class FolderWatcher {
    private var source: DispatchSourceFileSystemObject?
    private let onChange: () -> Void

    init(onChange: @escaping () -> Void) { self.onChange = onChange }

    func start(_ url: URL) {
        stop()
        let fd = open(url.path, O_EVTONLY)
        guard fd >= 0 else { return }
        let s = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: fd, eventMask: [.write, .rename, .delete, .extend, .attrib, .link], queue: .main)
        s.setEventHandler { [weak self] in self?.onChange() }
        s.setCancelHandler { close(fd) }
        s.resume()
        source = s
    }

    func stop() {
        source?.cancel()
        source = nil
    }
}

// MARK: - App

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate, UNUserNotificationCenterDelegate {
    var statusItem: NSStatusItem!
    let menu = NSMenu()
    var watcher: FolderWatcher!
    var timer: Timer?
    var pendingScan: DispatchWorkItem?

    var queue: [URL] = []
    var isWorking = false
    var currentName: String?
    var currentProgress: Double = 0
    var lastMessage: String?
    var failed: [String: Date] = [:]

    func applicationDidFinishLaunching(_ notification: Notification) {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        statusItem.button?.imagePosition = .imageLeading
        updateIcon()
        menu.delegate = self
        statusItem.menu = menu

        let center = UNUserNotificationCenter.current()
        center.delegate = self
        center.requestAuthorization(options: [.alert, .sound]) { _, _ in }

        if !Settings.didFirstRun {
            Settings.didFirstRun = true
            Settings.baseline = Date()
            try? SMAppService.mainApp.register()
        }

        watcher = FolderWatcher { [weak self] in self?.scheduleScan() }
        watcher.start(Settings.folderURL)
        timer = Timer.scheduledTimer(withTimeInterval: 20, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.scan() }
        }
        scheduleScan()

        if KeyStore.load() == nil {
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { [weak self] in self?.askForKey() }
        }
    }

    // MARK: Menu

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()

        let status: String
        if let name = currentName {
            status = "מתרגם: \(name) — \(Int(currentProgress * 100))%"
                + (queue.isEmpty ? "" : "  (+\(queue.count) בתור)")
        } else if KeyStore.load() == nil {
            status = "⚠️ חסר מפתח API"
        } else {
            status = "● מאזין לקבצים חדשים"
        }
        menu.addItem(info(status))
        if let m = lastMessage { menu.addItem(info(m)) }

        menu.addItem(.separator())
        menu.addItem(info("תיקייה: \(Settings.folderURL.lastPathComponent)"))
        menu.addItem(action("בחר תיקייה להאזנה…", #selector(chooseFolder)))
        menu.addItem(action("פתח את התיקייה", #selector(openFolder)))

        menu.addItem(.separator())
        menu.addItem(action("תרגם קובץ עכשיו…", #selector(pickFiles)))

        menu.addItem(.separator())
        menu.addItem(action(KeyStore.load() == nil ? "הגדר מפתח API…" : "מפתח API ✓  (החלפה…)", #selector(askForKey)))

        let models = NSMenu()
        let q = action("Sonnet — איכות גבוהה (מומלץ)", #selector(setModel(_:)))
        q.representedObject = Models.quality
        q.state = Settings.model == Models.quality ? .on : .off
        let f = action("Haiku — מהיר וזול יותר", #selector(setModel(_:)))
        f.representedObject = Models.fast
        f.state = Settings.model == Models.fast ? .on : .off
        models.addItem(q)
        models.addItem(f)
        let modelItem = NSMenuItem(title: "מודל תרגום", action: nil, keyEquivalent: "")
        modelItem.submenu = models
        menu.addItem(modelItem)

        let rtl = action("תיקון פיסוק לנגנים וטלוויזיות", #selector(toggleRTL))
        rtl.state = Settings.rtlFix ? .on : .off
        menu.addItem(rtl)

        let login = action("הפעל אוטומטית עם הדלקת המחשב", #selector(toggleLogin))
        login.state = SMAppService.mainApp.status == .enabled ? .on : .off
        menu.addItem(login)

        menu.addItem(.separator())
        menu.addItem(action("יציאה", #selector(quit), key: "q"))
    }

    func action(_ title: String, _ sel: Selector, key: String = "") -> NSMenuItem {
        let i = NSMenuItem(title: title, action: sel, keyEquivalent: key)
        i.target = self
        return i
    }

    func info(_ title: String) -> NSMenuItem {
        let i = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        i.isEnabled = false
        return i
    }

    func updateIcon() {
        guard let b = statusItem?.button else { return }
        let working = currentName != nil
        let name = working ? "captions.bubble.fill" : "captions.bubble"
        if let img = NSImage(systemSymbolName: name, accessibilityDescription: appTitle) {
            img.isTemplate = true
            b.image = img
            b.title = working ? " \(Int(currentProgress * 100))%" : ""
        } else {
            b.image = nil
            b.title = working ? "עב \(Int(currentProgress * 100))%" : "עב"
        }
    }

    // MARK: Actions

    @objc func chooseFolder() {
        NSApp.activate(ignoringOtherApps: true)
        let p = NSOpenPanel()
        p.canChooseDirectories = true
        p.canChooseFiles = false
        p.allowsMultipleSelection = false
        p.prompt = "בחר"
        p.message = "בחר את התיקייה שהאפליקציה תאזין לה"
        p.directoryURL = Settings.folderURL
        guard p.runModal() == .OK, let u = p.url else { return }
        Settings.folderURL = u
        Settings.baseline = Date()
        failed.removeAll()
        watcher.start(u)
        Notifier.send("התיקייה עודכנה", "מאזין עכשיו לתיקייה: \(u.lastPathComponent)")
        scheduleScan()
    }

    @objc func openFolder() {
        NSWorkspace.shared.open(Settings.folderURL)
    }

    @objc func pickFiles() {
        NSApp.activate(ignoringOtherApps: true)
        let p = NSOpenPanel()
        p.canChooseFiles = true
        p.canChooseDirectories = false
        p.allowsMultipleSelection = true
        if let t = UTType(filenameExtension: "srt") { p.allowedContentTypes = [t] }
        p.prompt = "תרגם"
        p.message = "בחר קובץ כתוביות באנגלית (.srt)"
        p.directoryURL = Settings.folderURL
        guard p.runModal() == .OK else { return }
        for u in p.urls where !queue.contains(u) { queue.append(u) }
        processNext()
    }

    @objc func setModel(_ sender: NSMenuItem) {
        if let m = sender.representedObject as? String { Settings.model = m }
    }

    @objc func toggleRTL() {
        Settings.rtlFix.toggle()
    }

    @objc func toggleLogin() {
        do {
            if SMAppService.mainApp.status == .enabled {
                try SMAppService.mainApp.unregister()
            } else {
                try SMAppService.mainApp.register()
            }
        } catch {
            showAlert("לא הצלחתי לשנות את ההגדרה",
                      "\(error.localizedDescription)\n\nודא שהאפליקציה נמצאת בתיקיית Applications.")
        }
        if SMAppService.mainApp.status == .requiresApproval {
            showAlert("צריך אישור קטן",
                      "פתח System Settings ← General ← Login Items והפעל את Subtitle Translator.")
        }
    }

    @objc func quit() {
        NSApp.terminate(nil)
    }

    @objc func askForKey() {
        NSApp.activate(ignoringOtherApps: true)
        let a = NSAlert()
        a.messageText = "מפתח API של Anthropic"
        a.informativeText = """
        1. היכנס ל-console.anthropic.com ← API Keys ← Create Key.
        2. לחץ Copy על המפתח.
        3. חזור לכאן ולחץ "הדבק מהלוח ושמור".
        """
        let field = NSSecureTextField(frame: NSRect(x: 0, y: 0, width: 320, height: 24))
        field.placeholderString = "sk-ant-…  (או השתמש בכפתור ההדבקה)"
        a.accessoryView = field
        a.addButton(withTitle: "הדבק מהלוח ושמור")
        a.addButton(withTitle: "שמור את מה שהוקלד")
        a.addButton(withTitle: "פתח את console.anthropic.com")
        a.addButton(withTitle: "ביטול")

        let r = a.runModal()
        var key: String?
        switch r {
        case .alertFirstButtonReturn:
            key = NSPasteboard.general.string(forType: .string)
        case .alertSecondButtonReturn:
            key = field.stringValue
        case .alertThirdButtonReturn:
            if let u = URL(string: "https://console.anthropic.com/settings/keys") { NSWorkspace.shared.open(u) }
            return
        default:
            return
        }

        guard let k = key?.trimmingCharacters(in: .whitespacesAndNewlines), k.hasPrefix("sk-ant-") else {
            showAlert("זה לא נראה כמו מפתח API", "מפתח של Anthropic מתחיל ב-sk-ant-. העתק אותו שוב ונסה שוב.")
            return
        }
        do {
            try KeyStore.save(k)
        } catch {
            showAlert("לא הצלחתי לשמור את המפתח", error.localizedDescription)
            return
        }
        Task { @MainActor in
            if await Translator.validate(k) {
                Notifier.send("המפתח נשמר ✓", "האפליקציה מוכנה לתרגם כתוביות")
                self.scheduleScan()
            } else {
                Notifier.send("המפתח נשמר, אבל לא אומת", "בדוק שהמפתח נכון ושיש קרדיט בחשבון Anthropic")
            }
        }
    }

    func showAlert(_ title: String, _ text: String) {
        NSApp.activate(ignoringOtherApps: true)
        let a = NSAlert()
        a.messageText = title
        a.informativeText = text
        a.addButton(withTitle: "אישור")
        a.runModal()
    }

    // MARK: Watching & queue

    func scheduleScan() {
        pendingScan?.cancel()
        let w = DispatchWorkItem { [weak self] in self?.scan() }
        pendingScan = w
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5, execute: w)
    }

    func scan() {
        let folder = Settings.folderURL
        let keys: [URLResourceKey] = [.contentModificationDateKey, .creationDateKey, .fileSizeKey]
        guard let items = try? FileManager.default.contentsOfDirectory(
            at: folder, includingPropertiesForKeys: keys, options: [.skipsHiddenFiles]) else { return }

        let now = Date()
        var needsRecheck = false
        for u in items where SRT.isSourceCandidate(u) {
            let v = try? u.resourceValues(forKeys: Set(keys))
            let mod = v?.contentModificationDate ?? .distantPast
            let created = v?.creationDate ?? mod
            guard max(mod, created) > Settings.baseline else { continue }
            if FileManager.default.fileExists(atPath: SRT.outputURL(for: u).path) { continue }
            if queue.contains(u) || currentName == u.lastPathComponent { continue }
            if let f = failed[u.path], f == mod { continue }
            // Wait until the download has finished writing.
            if now.timeIntervalSince(mod) < 2 || (v?.fileSize ?? 0) == 0 {
                needsRecheck = true
                continue
            }
            queue.append(u)
        }
        if needsRecheck { scheduleScan() }
        processNext()
    }

    func processNext() {
        guard !isWorking, !queue.isEmpty else { return }
        guard let key = KeyStore.load() else {
            queue.removeAll()
            Notifier.send("חסר מפתח API", "לחץ על אייקון הכתוביות בשורת התפריטים ובחר \"הגדר מפתח API\"")
            return
        }

        let u = queue.removeFirst()
        isWorking = true
        currentName = u.lastPathComponent
        currentProgress = 0
        updateIcon()

        let model = Settings.model
        let rtl = Settings.rtlFix
        Task { @MainActor in
            var outcome: Result<URL, Error>
            do {
                let out = try await Job.run(u, key: key, model: model, rtl: rtl) { p in
                    Task { @MainActor in
                        self.currentProgress = p
                        self.updateIcon()
                    }
                }
                outcome = .success(out)
            } catch {
                outcome = .failure(error)
            }

            self.isWorking = false
            self.currentName = nil
            self.updateIcon()

            switch outcome {
            case .success(let out):
                self.lastMessage = "אחרון: \(out.lastPathComponent) ✓"
                Notifier.send("התרגום מוכן ✓", out.lastPathComponent, path: out.path)
            case .failure(let err):
                let mod = (try? u.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
                self.failed[u.path] = mod ?? Date()
                if case JobError.alreadyHebrew = err {
                    // Nothing to do — silently skip.
                } else {
                    self.lastMessage = "נכשל: \(u.lastPathComponent)"
                    Notifier.send("התרגום נכשל", "\(u.lastPathComponent): \(err.localizedDescription)")
                }
                if let ae = err as? APIError, ae.fatal { self.queue.removeAll() }
            }
            self.processNext()
        }
    }

    // MARK: Notification delegate

    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter,
                                            willPresent notification: UNNotification,
                                            withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void) {
        completionHandler([.banner, .list, .sound])
    }

    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter,
                                            didReceive response: UNNotificationResponse,
                                            withCompletionHandler completionHandler: @escaping () -> Void) {
        let path = response.notification.request.content.userInfo["path"] as? String
        if let p = path {
            Task { @MainActor in
                NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: p)])
            }
        }
        completionHandler()
    }
}

// MARK: - Entry point

@main
enum Main {
    @MainActor static var delegate: AppDelegate?

    @MainActor static func main() {
        let app = NSApplication.shared
        let d = AppDelegate()
        delegate = d
        app.delegate = d
        app.setActivationPolicy(.accessory)
        app.run()
    }
}

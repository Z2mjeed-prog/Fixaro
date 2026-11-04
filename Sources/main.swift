// Fixaro — private, AI-powered autocorrect and rephrasing for every app on your Mac.
// https://github.com/Z2mjeed-prog/Fixaro · MIT License
//
// How it works:
// 1) The Mac's spell checker flags a wrong word when you press Space.
// 2) A local AI model (Ollama, or Apple Intelligence where available) picks the right fix,
//    looking at the words before AND after the typo.
// 3) The word is swapped in. Backspace right after a fix, or ⌃⌥Z, undoes it.
// 4) Select text and press ⌃⌥R to rephrase it, or ⌃⌥S to pick a style or type how to rewrite it.
// Everything runs on this Mac. Nothing you type is sent anywhere.

import Cocoa
import ApplicationServices
import ServiceManagement
#if canImport(FoundationModels)
import FoundationModels
#endif

// MARK: - Constants

let kSyntheticMarker: Int64 = 0x46495852          // tags events Fixaro types itself
let kReplayMarker: Int64 = kSyntheticMarker + 1     // the user's own keys, re-sent after Fixaro finished typing
let kComboMarker: Int64 = kSyntheticMarker + 3      // ⌘C / ⌘V for rephrase (not counted)
let kLLMTimeout: Double = 1.5                      // seconds before falling back to the spell checker
let kNextWordWait: Double = 1.0                    // how long to wait for the next word before asking the AI anyway
let excludedByDefault: [String] = [
    "com.apple.Terminal", "com.googlecode.iterm2", "dev.warp.Warp-Stable",
    "com.microsoft.VSCode", "com.apple.dt.Xcode", "com.todesktop.230313mzl4w4u92",
    "com.sublimetext.4", "com.apple.keychainaccess"
]
let systemPrompt = "You are a spelling corrector. The user typed a misspelled English word. Using the sentence for context, reply with ONLY the single correctly spelled word they meant. No explanation, no quotes, no punctuation."

enum EngineChoice: String { case auto, apple, ollama, spell }

func systemFor(_ base: String, model: String) -> String {
    model.lowercased().contains("qwen") ? base + " /no_think" : base
}

var logURL: URL {
    // Developer option: add a FixaroDevLogDir key (a folder path) to Info.plist to log there instead.
    // A file named "force-keystrokes" in that folder makes Fixaro always fix by retyping (for testing).
    if let dir = Bundle.main.object(forInfoDictionaryKey: "FixaroDevLogDir") as? String, !dir.isEmpty {
        return URL(fileURLWithPath: dir).appendingPathComponent("fixaro.log")
    }
    return FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Logs/Fixaro.log")
}

func logLine(_ s: String) {
    let line = "\(ISO8601DateFormatter().string(from: Date()))  \(s)\n"
    guard let data = line.data(using: .utf8) else { return }
    if let h = try? FileHandle(forWritingTo: logURL) {
        h.seekToEndOfFile(); h.write(data); try? h.close()
    } else {
        try? data.write(to: logURL)
    }
}

// MARK: - Small helpers

func hasNonLatinLetters(_ s: String) -> Bool {
    s.unicodeScalars.contains { $0.properties.isAlphabetic && $0.value > 0x024F }
}

func editDistance(_ a: String, _ b: String) -> Int {
    let x = Array(a), y = Array(b)
    if x.isEmpty { return y.count }
    if y.isEmpty { return x.count }
    var prev = Array(0...y.count)
    var cur = Array(repeating: 0, count: y.count + 1)
    for i in 1...x.count {
        cur[0] = i
        for j in 1...y.count {
            cur[j] = min(prev[j] + 1, cur[j - 1] + 1, prev[j - 1] + (x[i - 1] == y[j - 1] ? 0 : 1))
        }
        swap(&prev, &cur)
    }
    return prev[y.count]
}

@MainActor
func matchCase(_ word: String, like original: String) -> String {
    guard let f = original.first, let w = word.first else { return word }
    if f.isUppercase { return String(word.prefix(1)).uppercased() + String(word.dropFirst()) }
    if w.isUppercase && original == original.lowercased() {
        let lower = word.lowercased()
        if NSSpellChecker.shared.checkSpelling(of: lower, startingAt: 0).location == NSNotFound { return lower }
    }
    return word
}

// MARK: - Typing (sends keystrokes)

@MainActor
enum Typist {
    static let source = CGEventSource(stateID: .hidSystemState)
    /// Keys Fixaro has sent that haven't come back through the keyboard watcher yet.
    static var outstanding = 0
    static var lastPost = Date.distantPast

    static func send(_ e: CGEvent, marker: Int64) {
        e.setIntegerValueField(.eventSourceUserData, value: marker)
        outstanding += 1
        lastPost = Date()
        e.post(tap: .cghidEventTap)
    }

    static func arrived() { if outstanding > 0 { outstanding -= 1 } }

    static func post(_ e: CGEvent?) {
        guard let e else { return }
        e.flags = []
        send(e, marker: kSyntheticMarker)
        usleep(1500)
    }

    static let comboSource = CGEventSource(stateID: .privateState)

    static func combo(_ keycode: CGKeyCode, _ flags: CGEventFlags) {
        for down in [true, false] {
            guard let e = CGEvent(keyboardEventSource: comboSource, virtualKey: keycode, keyDown: down) else { continue }
            e.flags = flags
            e.setIntegerValueField(.eventSourceUserData, value: kComboMarker)
            e.post(tap: .cgSessionEventTap)
            usleep(5000)
        }
    }

    static func key(_ keycode: CGKeyCode, _ flags: CGEventFlags) {
        for down in [true, false] {
            guard let e = CGEvent(keyboardEventSource: source, virtualKey: keycode, keyDown: down) else { continue }
            e.flags = flags
            send(e, marker: kSyntheticMarker)
            usleep(1500)
        }
    }

    /// Wait until the user lets go of Control/Option/Shift/Command (at most `maxWait` seconds).
    static func waitForModifierRelease(maxWait: Double = 1.5) async {
        let steps = max(1, Int(maxWait / 0.02))
        for _ in 0..<steps {
            let f = CGEventSource.flagsState(.hidSystemState)
            if !f.contains(.maskControl) && !f.contains(.maskAlternate)
                && !f.contains(.maskShift) && !f.contains(.maskCommand) { return }
            try? await Task.sleep(nanoseconds: 20_000_000)
        }
    }

    static func backspace(_ n: Int) {
        guard n > 0 else { return }
        for _ in 0..<n {
            post(CGEvent(keyboardEventSource: source, virtualKey: 51, keyDown: true))
            post(CGEvent(keyboardEventSource: source, virtualKey: 51, keyDown: false))
        }
    }

    static func type(_ s: String) {
        for ch in s {
            let units = Array(String(ch).utf16)
            for down in [true, false] {
                guard let e = CGEvent(keyboardEventSource: source, virtualKey: 0, keyDown: down) else { continue }
                e.keyboardSetUnicodeString(stringLength: units.count, unicodeString: units)
                post(e)
            }
        }
    }
}

// MARK: - Local AI server (Ollama, or any app with an OpenAI-compatible API)

struct OllamaModel { let name: String; let size: Int64 }   // size is 0 when the server doesn't report it

enum ServerKind: String { case ollama, openai }

enum Ollama {
    static var kind: ServerKind = .ollama
    static var base = "http://127.0.0.1:11434"     // for .openai, e.g. http://localhost:1234/v1

    static func hostPort(_ s: String) -> String {
        guard let u = URL(string: s), let h = u.host else { return s }
        if let p = u.port { return "\(h):\(p)" }
        return h
    }

    static var displayName: String { kind == .ollama ? "Ollama" : "AI app at \(hostPort(base))" }

    static func listModels() async -> [OllamaModel]? {
        let path = kind == .ollama ? "/api/tags" : "/models"
        guard let url = URL(string: base + path) else { return nil }
        var req = URLRequest(url: url)
        req.timeoutInterval = 2
        guard let result = try? await URLSession.shared.data(for: req),
              let obj = try? JSONSerialization.jsonObject(with: result.0) as? [String: Any] else { return nil }
        let arr = (obj[kind == .ollama ? "models" : "data"] as? [[String: Any]]) ?? []
        return arr.compactMap { m in
            guard let n = (m["name"] as? String) ?? (m["id"] as? String) else { return nil }
            if n.lowercased().contains("embed") { return nil }        // embedding models can't write text
            let size = (m["size"] as? NSNumber)?.int64Value ?? 0
            return OllamaModel(name: n, size: size)
        }
    }

    static func generate(model: String, system: String, prompt: String, numPredict: Int = 16, timeout: Double = 30,
                         keepAlive: String = "30m") async -> String? {
        if kind == .openai {
            return await chat(model: model, system: system, prompt: prompt, maxTokens: numPredict, timeout: timeout)
        }
        guard let url = URL(string: base + "/api/generate") else { return nil }
        for sendThinkFlag in [true, false] {
            var body: [String: Any] = [
                "model": model, "prompt": prompt, "stream": false, "keep_alive": keepAlive,
                "options": ["temperature": 0, "num_predict": numPredict]
            ]
            if !system.isEmpty { body["system"] = system }
            if sendThinkFlag { body["think"] = false }
            var req = URLRequest(url: url)
            req.httpMethod = "POST"
            req.timeoutInterval = timeout
            req.setValue("application/json", forHTTPHeaderField: "Content-Type")
            req.httpBody = try? JSONSerialization.data(withJSONObject: body)
            guard let result = try? await URLSession.shared.data(for: req) else { return nil }
            let status = (result.1 as? HTTPURLResponse)?.statusCode ?? 0
            if status == 200, let obj = try? JSONSerialization.jsonObject(with: result.0) as? [String: Any] {
                return obj["response"] as? String
            }
            if !sendThinkFlag {
                logLine("Ollama error \(status): \(String(data: result.0, encoding: .utf8) ?? "")")
                return nil
            }
        }
        return nil
    }

    /// OpenAI-compatible chat API (LM Studio, llama.cpp, MLX servers, Jan, …).
    static func chat(model: String, system: String, prompt: String, maxTokens: Int, timeout: Double) async -> String? {
        guard let url = URL(string: base + "/chat/completions") else { return nil }
        var messages: [[String: String]] = []
        if !system.isEmpty { messages.append(["role": "system", "content": system]) }
        messages.append(["role": "user", "content": prompt])
        let body: [String: Any] = ["model": model, "messages": messages, "temperature": 0,
                                   "max_tokens": maxTokens, "stream": false]
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.timeoutInterval = timeout
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try? JSONSerialization.data(withJSONObject: body)
        guard let result = try? await URLSession.shared.data(for: req) else { return nil }
        let status = (result.1 as? HTTPURLResponse)?.statusCode ?? 0
        guard status == 200,
              let obj = try? JSONSerialization.jsonObject(with: result.0) as? [String: Any],
              let choices = obj["choices"] as? [[String: Any]],
              let message = choices.first?["message"] as? [String: Any],
              let content = message["content"] as? String else {
            let text = String(data: result.0, encoding: .utf8) ?? ""
            logLine("AI app error \(status): \(text.prefix(200))")
            return nil
        }
        return content
    }

    /// Download a model with Ollama, reporting progress ("42%").
    static func pull(_ name: String, progress: @escaping @MainActor (String) -> Void) async -> Bool {
        guard kind == .ollama, let url = URL(string: base + "/api/pull") else { return false }
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.timeoutInterval = 3600
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try? JSONSerialization.data(withJSONObject: ["model": name, "name": name, "stream": true])
        do {
            let (bytes, response) = try await URLSession.shared.bytes(for: req)
            guard (response as? HTTPURLResponse)?.statusCode == 200 else { return false }
            var lastShown = ""
            for try await line in bytes.lines {
                guard let data = line.data(using: .utf8),
                      let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { continue }
                if let err = obj["error"] as? String { logLine("download error: \(err)"); return false }
                let status = obj["status"] as? String ?? ""
                if status == "success" { return true }
                var shown = status
                if let total = (obj["total"] as? NSNumber)?.doubleValue, total > 0,
                   let done = (obj["completed"] as? NSNumber)?.doubleValue {
                    shown = "\(Int(done / total * 100))%"
                }
                if shown != lastShown && !shown.isEmpty {
                    lastShown = shown
                    await progress(shown)
                }
            }
        } catch {
            logLine("download error: \(error.localizedDescription)")
        }
        return false
    }
}

// MARK: - Apple Intelligence (on-device)

#if canImport(FoundationModels)
@available(macOS 26.0, *)
enum AppleLLM {
    static var isAvailable: Bool {
        if case .available = SystemLanguageModel.default.availability { return true }
        return false
    }
    static func generateRaw(prompt: String) async -> String? {
        let session = LanguageModelSession()
        do { return try await session.respond(to: prompt).content }
        catch { logLine("Apple Intelligence error: \(error)"); return nil }
    }
    static func generate(prompt: String) async -> String? {
        let session = LanguageModelSession(instructions: "You are a spelling corrector. The user typed a misspelled English word. Using the sentence for context, reply with ONLY the single correctly spelled word they meant. No explanation, no quotes, no punctuation.")
        do {
            let r = try await session.respond(to: prompt)
            return r.content
        } catch {
            logLine("Apple Intelligence error: \(error)")
            return nil
        }
    }
}
#endif

func appleAvailable() -> Bool {
    #if canImport(FoundationModels)
    if #available(macOS 26.0, *) { return AppleLLM.isAvailable }
    #endif
    return false
}

func appleGenerateRaw(_ prompt: String) async -> String? {
    #if canImport(FoundationModels)
    if #available(macOS 26.0, *) { return await AppleLLM.generateRaw(prompt: prompt) }
    #endif
    return nil
}

func appleGenerate(_ prompt: String) async -> String? {
    #if canImport(FoundationModels)
    if #available(macOS 26.0, *) { return await AppleLLM.generate(prompt: prompt) }
    #endif
    return nil
}

// MARK: - Event tap callback (C function)

func fixaroTapCallback(proxy: CGEventTapProxy, type: CGEventType, event: CGEvent,
                        refcon: UnsafeMutableRawPointer?) -> Unmanaged<CGEvent>? {
    guard let refcon else { return Unmanaged.passUnretained(event) }
    let app = Unmanaged<AppDelegate>.fromOpaque(refcon).takeUnretainedValue()
    let swallow = MainActor.assumeIsolated { app.handle(type: type, event: event) }
    return swallow ? nil : Unmanaged.passUnretained(event)
}

// MARK: - App

struct PendingFix {
    let id: Int
    let core: String       // the misspelled word
    let trailing: String   // punctuation typed right after it, e.g. "," or "."
    var tail: String       // anything typed after the word's space while we waited
    let fallback: String?  // spell checker's own suggestion
    let guesses: [String]  // spell checker's candidates
    let lead: String       // text before the word
    var asked: Bool        // decision already requested (AI, spell checker or learned)
}

/// A fix Fixaro made recently. It can still be undone (⌃⌥Z) until you've typed 3 more words.
struct RecentFix {
    let original: String
    let corrected: String
    let trailing: String
    var tail: String       // what you typed after it
}

/// What Fixaro has learned from you (saved in ~/Library/Application Support/Fixaro/learned.json).
struct LearnedFix: Codable {
    var to: String
    var n: Int
    var mixed: Bool?        // you kept different fixes for this typo (frim → from / firm): the context decides
}
struct Learned: Codable {
    var version: Int? = 2
    var fixes: [String: LearnedFix] = [:]   // typo → the fix you kept (used instantly once kept twice)
    var undos: [String: Int] = [:]          // typo → how many times you undid Fixaro's fix
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate, NSTextFieldDelegate, NSWindowDelegate {
    var statusItem: NSStatusItem!
    var tap: CFMachPort?
    var permissionTimer: Timer?

    // What's being typed right now
    var word = ""
    var context = ""
    var untrusted = true      // after a click/arrow we don't know where the cursor is
    var pendings: [PendingFix] = []   // words waiting for the AI, oldest first
    var recentFixes: [RecentFix] = []
    var undoArmed = false                 // Backspace right now would undo the fix just made
    var learned = Learned()
    var nextID = 0

    // Settings
    let defaults = UserDefaults.standard
    var enabled: Bool {
        get { defaults.object(forKey: "enabled") as? Bool ?? true }
        set { defaults.set(newValue, forKey: "enabled"); updateIcon() }
    }
    /// Off = rephrase only: ⌃⌥R still works, but typing is left alone and the word-fix model isn't loaded
    var fixTyping: Bool {
        get { defaults.object(forKey: "fixTyping") as? Bool ?? false }    // off until you turn it on
        set { defaults.set(newValue, forKey: "fixTyping") }
    }
    var engineChoice: EngineChoice {
        get { EngineChoice(rawValue: defaults.string(forKey: "engine") ?? "") ?? .auto }
        set { defaults.set(newValue.rawValue, forKey: "engine"); resolveEngine() }
    }
    var serverKind: ServerKind {
        get { ServerKind(rawValue: defaults.string(forKey: "serverKind") ?? "") ?? .ollama }
        set { defaults.set(newValue.rawValue, forKey: "serverKind") }
    }
    var serverURL: String {
        get { defaults.string(forKey: "serverURL") ?? "http://127.0.0.1:11434" }
        set { defaults.set(newValue, forKey: "serverURL") }
    }
    var downloadStatus: String?
    var aiReachable = false                           // the AI app answered (it may still have no models)
    var lastModelRefresh = Date.distantPast

    var rephraseModelSetting: String? {
        get { defaults.string(forKey: "rephraseModel") }
        set { defaults.set(newValue, forKey: "rephraseModel") }
    }
    var ollamaModel: String? {
        get { defaults.string(forKey: "ollamaModel") }
        set { defaults.set(newValue, forKey: "ollamaModel") }
    }
    var excludedApps: Set<String> = [] {
        didSet { defaults.set(Array(excludedApps), forKey: "excludedApps") }
    }

    // Engines
    var appleOK = false
    var ollamaModels: [OllamaModel] = []
    var activeEngine: EngineChoice = .spell

    // Spelling
    let checker = NSSpellChecker.shared
    let spellTag = NSSpellChecker.uniqueSpellDocumentTag()
    var wordList: Set<String> = []
    var wordListMTime: Date?
    var sessionIgnore: Set<String> = []
    var lastFixText = "none yet"
    var lastUndone: String?

    var wordListURL: URL {
        let dir = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/Fixaro", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("words.txt")
    }

    // MARK: Launch

    func applicationDidFinishLaunching(_ notification: Notification) {
        logLine("Fixaro starting · macOS \(ProcessInfo.processInfo.operatingSystemVersionString)")
        excludedApps = Set(defaults.stringArray(forKey: "excludedApps") ?? excludedByDefault)

        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        let menu = NSMenu()
        menu.delegate = self
        statusItem.menu = menu
        updateIcon()

        migrateEarlyData()
        setupWordList()
        loadLearned()
        NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.reset() }
        }
        Timer.scheduledTimer(withTimeInterval: 10, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.reloadWordList() }
        }
        // Pick up models you download or load later, without restarting
        Timer.scheduledTimer(withTimeInterval: 30, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                Task { await self.refreshModelList() }
            }
        }
        Ollama.kind = serverKind
        Ollama.base = serverURL

        startWhenTrusted()
        Task { await self.refreshEngines() }
    }

    func startWhenTrusted() {
        if AXIsProcessTrusted() {
            installTap()
            if !welcomed { showWelcome() }
            return
        }
        showWelcome()                                         // explains the permission, with a button to allow it
        logLine("Waiting for Accessibility permission…")
        updateIcon()
        permissionTimer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] t in
            MainActor.assumeIsolated {
                guard let self else { return }
                if AXIsProcessTrusted() {
                    t.invalidate()
                    self.permissionTimer = nil
                    self.installTap()
                }
            }
        }
    }

    func installTap() {
        let types: [CGEventType] = [.keyDown, .keyUp, .leftMouseDown, .rightMouseDown, .otherMouseDown]
        var mask: CGEventMask = 0
        for t in types { mask |= CGEventMask(1) << CGEventMask(t.rawValue) }
        let me = Unmanaged.passUnretained(self).toOpaque()
        guard let tap = CGEvent.tapCreate(tap: .cgSessionEventTap, place: .headInsertEventTap,
                                          options: .defaultTap, eventsOfInterest: mask,
                                          callback: fixaroTapCallback, userInfo: me) else {
            logLine("ERROR: could not start the keyboard watcher. Quit and reopen Fixaro after granting permission.")
            return
        }
        self.tap = tap
        let src = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
        CFRunLoopAddSource(CFRunLoopGetMain(), src, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
        logLine("Keyboard watcher running.")
        updateIcon()
    }

    // MARK: Engines

    func refreshEngines() async {
        appleOK = appleAvailable()
        let fetched = await Ollama.listModels()
        aiReachable = fetched != nil
        ollamaModels = fetched ?? []
        if ollamaModel == nil || !ollamaModels.contains(where: { $0.name == ollamaModel }) {
            ollamaModel = pickDefaultModel(ollamaModels)
        }
        if rephraseModelSetting == nil || !ollamaModels.contains(where: { $0.name == rephraseModelSetting }) {
            rephraseModelSetting = pickRephraseModel(ollamaModels)
        }
        resolveEngine()
        let ramGB = Double(ProcessInfo.processInfo.physicalMemory) / 1_073_741_824
        let sizes: [String] = ollamaModels.map { m in
            let gb = Double(m.size) / 1e9
            return m.name + " " + String(format: "%.1f GB", gb)
        }
        let memText = String(format: "%.0f GB", ramGB)
        let wordModel = ollamaModel ?? "none"
        let rephModel = rephraseModelSetting ?? "none"
        logLine("Mac memory: \(memText) · models: \(sizes.joined(separator: ", ")) · word fixes: \(wordModel) · rephrase: \(rephModel)")
        logLine("Engines · Apple Intelligence: \(appleOK ? "available" : "not available") · \(Ollama.displayName) models: \(ollamaModels.isEmpty ? "none / not running" : ollamaModels.map(\.name).joined(separator: ", ")) · Using: \(engineLabel(activeEngine))")
        lastModelRefresh = Date()
        await warmUp()
    }

    /// Re-read the model list (cheap): new downloads appear in the menu without restarting.
    func refreshModelList() async {
        lastModelRefresh = Date()
        let fetched = await Ollama.listModels()
        aiReachable = fetched != nil
        let ms = fetched ?? []
        let names = ms.map(\.name)
        guard names != ollamaModels.map(\.name) else { return }
        ollamaModels = ms
        if ollamaModel == nil || !names.contains(ollamaModel ?? "") { ollamaModel = pickDefaultModel(ms) }
        if rephraseModelSetting == nil || !names.contains(rephraseModelSetting ?? "") {
            rephraseModelSetting = pickRephraseModel(ms)
        }
        resolveEngine()
        logLine("Models at \(Ollama.displayName): \(names.isEmpty ? "none" : names.joined(separator: ", "))")
    }

    /// Image/vision models can write text too, but text models are the better default.
    func textFirst(_ ms: [OllamaModel]) -> [OllamaModel] {
        let text = ms.filter { m in !["llava", "vision", "-vl", "vl:", "ocr"].contains(where: { m.name.lowercased().contains($0) }) }
        return text.isEmpty ? ms : text
    }

    func warmUp() async {
        guard fixTyping else { return }                       // rephrase only: no need to load the word-fix model
        let sample = makePrompt(word: "helo", before: "I said ", after: " to her", guesses: ["hello", "help", "hero"])
        let start = Date()
        switch activeEngine {
        case .apple:
            let r = await appleGenerate(sample)
            logLine("Apple Intelligence warm-up: \(r?.trimmingCharacters(in: .whitespacesAndNewlines) ?? "no reply") in \(Int(Date().timeIntervalSince(start) * 1000)) ms")
        case .ollama:
            guard let m = ollamaModel else { return }
            let r = await Ollama.generate(model: m, system: systemFor(systemPrompt, model: m), prompt: sample, numPredict: 24)
            logLine("\(Ollama.displayName) \(m) warm-up: \(r?.trimmingCharacters(in: .whitespacesAndNewlines) ?? "no reply") in \(Int(Date().timeIntervalSince(start) * 1000)) ms")
        default: break
        }
    }

    /// Biggest installed text model that comfortably fits in this Mac's memory.
    func pickRephraseModel(_ all: [OllamaModel]) -> String? {
        let ms = textFirst(all)
        let ram = Double(ProcessInfo.processInfo.physicalMemory)
        let fits = ms.filter { $0.size > 0 && Double($0.size) <= ram * 0.55 }.sorted { $0.size > $1.size }
        return (fits.first ?? ms.sorted { $0.size < $1.size }.first)?.name
    }

    func pickDefaultModel(_ all: [OllamaModel]) -> String? {
        let ms = textFirst(all)
        let preferred = ["qwen3.5:4b", "qwen3.5:2b", "phi4-mini", "llama3.2:3b", "gemma4:e2b", "qwen3:4b", "gemma4:e4b"]
        for p in preferred {
            if let m = ms.first(where: { $0.name == p || $0.name.hasPrefix(p + ":") }) { return m.name }
        }
        let gb: Int64 = 1_000_000_000
        let fits = ms.filter { $0.size > 0 && $0.size <= gb * 7 / 2 }.sorted { $0.size > $1.size }
        return (fits.first ?? ms.sorted { $0.size < $1.size }.first)?.name
    }

    func resolveEngine() {
        switch engineChoice {
        case .auto:   activeEngine = appleOK ? .apple : (ollamaModel != nil ? .ollama : .spell)
        case .apple:  activeEngine = appleOK ? .apple : .spell
        case .ollama: activeEngine = ollamaModel != nil ? .ollama : .spell
        case .spell:  activeEngine = .spell
        }
    }

    func engineLabel(_ e: EngineChoice) -> String {
        switch e {
        case .apple: return "Apple Intelligence (on-device)"
        case .ollama: return "\(Ollama.displayName) · \(ollamaModel ?? "no model")"
        case .spell, .auto: return "Spell checker only"
        }
    }

    // MARK: Keystrokes

    func handle(type: CGEventType, event: CGEvent) -> Bool {
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            if let tap { CGEvent.tapEnable(tap: tap, enable: true) }
            return false
        }
        let marker = event.getIntegerValueField(.eventSourceUserData)
        if marker == kSyntheticMarker {                      // one of Fixaro's own keys came through
            Typist.arrived()
            if !isHolding { flushHeld() }
            return false
        }
        if marker == kComboMarker { return false }
        let isReplay = marker == kReplayMarker
        if isReplay {                                        // a held key of the user's, now re-sent in order
            Typist.arrived()
            if !isHolding { flushHeld() }
        } else if type == .keyDown || type == .keyUp {
            releaseIfStuck()
            if isHolding || !held.isEmpty {                  // Fixaro is mid-typing: keep this key until it's done
                if let copy = event.copy() { held.append((type, copy)); return true }
            }
        }
        if type == .keyUp { return false }
        if promptPanel != nil { return false }               // the ⌃⌥S popup is open: those keys are for it
        guard enabled else { return false }
        if type != .keyDown { reset(); return false }

        if let bid = NSWorkspace.shared.frontmostApplication?.bundleIdentifier, excludedApps.contains(bid) {
            reset(); return false
        }
        let flags = event.flags
        if flags.contains(.maskControl) && flags.contains(.maskAlternate) && !flags.contains(.maskCommand) {
            switch event.getIntegerValueField(.keyboardEventKeycode) {
            case 15:                                                       // ⌃⌥R = rephrase in your usual style
                reset()
                Task { await self.rephraseSelection(choose: false) }
                return true
            case 1:                                                        // ⌃⌥S = pick a style or type how
                reset()
                Task { await self.rephraseSelection(choose: true) }
                return true
            case 6:                                                        // ⌃⌥Z = undo the last fix
                Task { await self.undoLastFixFromShortcut() }
                return true
            default: break
            }
        }
        if !fixTyping { return false }                        // rephrase only: leave typing alone
        if flags.contains(.maskCommand) || flags.contains(.maskControl) { reset(); return false }

        let keycode = event.getIntegerValueField(.keyboardEventKeycode)
        switch keycode {
        case 51:
            return handleBackspace()
        case 36, 76:                                                       // return / enter
            return handleReturn(flags: flags)
        case 48, 53, 117, 115, 119, 116, 121, 123, 124, 125, 126:          // tab, esc, arrows, home/end…
            reset(); return false
        default:
            break
        }

        var len = 0
        var buf = [UniChar](repeating: 0, count: 8)
        event.keyboardGetUnicodeString(maxStringLength: 8, actualStringLength: &len, unicodeString: &buf)
        guard len > 0 else { return false }
        let s = String(utf16CodeUnits: buf, count: len)
        if s.unicodeScalars.contains(where: { $0.value < 0x20 || (0xF700...0xF8FF).contains($0.value) }) {
            reset(); return false
        }
        undoArmed = false
        for ch in s { typed(ch) }
        return false
    }

    func typed(_ ch: Character) {
        context.append(ch)
        if context.count > 300 { context = String(context.suffix(300)) }
        for i in pendings.indices { pendings[i].tail.append(ch) }
        for i in recentFixes.indices { recentFixes[i].tail.append(ch) }
        if ch == " " {
            // A word was just finished: waiting typos now have a word after them, so the AI can decide
            let ready = pendings.filter { !$0.asked && $0.tail.contains(where: { !$0.isWhitespace }) }.map(\.id)
            for id in ready { askAI(id) }
            settleRecentFixes()
            let token = word
            let wasUntrusted = untrusted
            word = ""
            untrusted = false
            guard !token.isEmpty else { return }
            if !wasUntrusted || cursorFollowsWord(token) { evaluate(token: token) }
        } else {
            word.append(ch)
        }
    }

    func handleBackspace() -> Bool {
        // Backspace right after a fix = undo it
        if undoArmed, pendings.isEmpty, let last = recentFixes.last, last.tail.isEmpty {
            undoArmed = false
            if undoFix(at: recentFixes.count - 1, byBackspace: true) { return true }
        }
        undoArmed = false
        // Deleting into a word Fixaro fixed means you're editing it yourself: stop tracking it
        recentFixes = recentFixes.compactMap { r in
            var r = r
            if r.tail.isEmpty { return nil }
            r.tail.removeLast()
            return r
        }
        if context.isEmpty { untrusted = true } else { context.removeLast() }
        // Deleting the space after a waiting word cancels that word's fix
        if let last = pendings.last, last.tail.isEmpty { pendings.removeLast() }
        for i in pendings.indices where !pendings[i].tail.isEmpty { pendings[i].tail.removeLast() }
        if !word.isEmpty {
            word.removeLast()
        } else if let sp = context.lastIndex(of: " ") {
            word = String(context[context.index(after: sp)...])
        } else {
            word = context
            if context.isEmpty { untrusted = true }
        }
        return false
    }

    /// Enter: fix the last word (and any words still waiting for the AI) instantly, then press Enter.
    func handleReturn(flags: CGEventFlags) -> Bool {
        undoArmed = false
        var lastWord: (core: String, trailing: String, corrected: String)? = nil
        let token = word
        if !token.isEmpty, !untrusted || cursorFollowsWord(token),
           let a = analyze(token), let fb = a.fallback {
            let corrected = matchCase(fb, like: a.core)
            if corrected != a.core { lastWord = (a.core, a.trailing, corrected) }
        }
        if lastWord == nil && pendings.isEmpty {
            startFreshLine()
            return false                          // nothing to fix: Enter goes through untouched
        }
        let keepFlags = flags.intersection([.maskShift, .maskAlternate])
        let lastWordFix = lastWord
        manualHold = true                         // hold anything typed after Enter until Enter itself is sent
        manualHoldSince = Date()
        Task {
            if let lw = lastWordFix {
                let oldText = lw.core + lw.trailing
                let newText = lw.corrected + lw.trailing
                let r = self.replaceWord(oldText, with: newText, tail: "")
                if r == .done {
                    for i in self.pendings.indices where self.pendings[i].tail.hasSuffix(oldText) {
                        self.pendings[i].tail = String(self.pendings[i].tail.dropLast(oldText.count)) + newText
                    }
                    for i in self.recentFixes.indices where self.recentFixes[i].tail.hasSuffix(oldText) {
                        self.recentFixes[i].tail = String(self.recentFixes[i].tail.dropLast(oldText.count)) + newText
                    }
                    self.recentFixes.append(RecentFix(original: lw.core, corrected: lw.corrected, trailing: lw.trailing, tail: ""))
                    self.lastFixText = "\(lw.core) → \(lw.corrected)"
                    logLine("fix: \(lw.core) → \(lw.corrected)  [spell checker, before Enter, \(self.lastMethod)]")
                    self.flashIcon()
                } else {
                    logLine("skip: \(lw.core) (the text there changed; left it alone)")
                }
            }
            while let p = self.pendings.last {
                if let fb = p.fallback {
                    let c = matchCase(fb, like: p.core)
                    if c != p.core, self.applyFix(p, corrected: c, source: "spell checker, before Enter") == .done { continue }
                }
                self.pendings.removeAll { $0.id == p.id }
            }
            await Typist.waitForModifierRelease(maxWait: 0.6)
            if self.manualHold {
                Typist.key(36, keepFlags)
                self.manualHold = false
                self.scheduleHoldCheck()          // held keys go out once our Enter has come through
            } else {
                logLine("hold: Enter was late; sent it anyway")
                Typist.key(36, keepFlags)
            }
            self.startFreshLine()
        }
        return true
    }

    /// After Enter the cursor is at the start of a fresh line or message, so the next word can be trusted.
    func startFreshLine() {
        commitRecentFixes()                   // Enter: you kept these fixes
        word = ""; context = ""; untrusted = false; pendings.removeAll(); undoArmed = false
    }

    func reset() {
        recentFixes.removeAll()               // click / app switch: we can't tell what happened to them
        word = ""; context = ""; untrusted = true; pendings.removeAll(); undoArmed = false
    }

    /// After a click or app switch we don't know where the cursor is. Ask the app (via Accessibility)
    /// whether the word we tracked really is the whole word right before the cursor.
    func cursorFollowsWord(_ token: String) -> Bool {
        guard let before = textBeforeCursor(utf16Count: token.utf16.count + 1),
              before.hasSuffix(token) else { return false }
        let prefix = before.dropLast(token.count)
        guard let ch = prefix.last else { return true }          // word starts the text
        return ch.isWhitespace
    }

    // MARK: Reading and changing text through Accessibility

    enum Outcome { case done, mismatch, unsupported }
    var lastMethod = ""

    func focusedElement() -> AXUIElement? {
        let system = AXUIElementCreateSystemWide()
        AXUIElementSetMessagingTimeout(system, 0.1)
        var ref: CFTypeRef?
        guard AXUIElementCopyAttributeValue(system, kAXFocusedUIElementAttribute as CFString, &ref) == .success,
              let ref, CFGetTypeID(ref) == AXUIElementGetTypeID() else { return nil }
        let el = ref as! AXUIElement
        AXUIElementSetMessagingTimeout(el, 0.1)
        return el
    }

    func selectedRange(_ el: AXUIElement) -> CFRange? {
        var ref: CFTypeRef?
        guard AXUIElementCopyAttributeValue(el, kAXSelectedTextRangeAttribute as CFString, &ref) == .success,
              let ref, CFGetTypeID(ref) == AXValueGetTypeID() else { return nil }
        var r = CFRange()
        guard AXValueGetValue(ref as! AXValue, .cfRange, &r) else { return nil }
        return r
    }

    @discardableResult
    func setSelectedRange(_ el: AXUIElement, _ range: CFRange) -> Bool {
        var r = range
        guard let v = AXValueCreate(.cfRange, &r) else { return false }
        return AXUIElementSetAttributeValue(el, kAXSelectedTextRangeAttribute as CFString, v) == .success
    }

    func string(_ el: AXUIElement, _ range: CFRange) -> String? {
        if range.length == 0 { return "" }
        var r = range
        if let v = AXValueCreate(.cfRange, &r) {
            var ref: CFTypeRef?
            if AXUIElementCopyParameterizedAttributeValue(el, kAXStringForRangeParameterizedAttribute as CFString,
                                                          v, &ref) == .success,
               let s = ref as? String { return s.replacingOccurrences(of: "\u{00A0}", with: " ") }
        }
        var countRef: CFTypeRef?
        if AXUIElementCopyAttributeValue(el, kAXNumberOfCharactersAttribute as CFString, &countRef) == .success,
           let n = countRef as? Int, n > 50_000 { return nil }
        var valueRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(el, kAXValueAttribute as CFString, &valueRef) == .success,
              let v = valueRef as? String else { return nil }
        let ns = v as NSString
        guard range.location >= 0, range.location + range.length <= ns.length else { return nil }
        return ns.substring(with: NSRange(location: range.location, length: range.length))
            .replacingOccurrences(of: "\u{00A0}", with: " ")
    }

    func textBeforeCursor(utf16Count: Int) -> String? {
        guard let el = focusedElement(), let sel = selectedRange(el), sel.length == 0 else { return nil }
        let start = max(0, sel.location - utf16Count)
        return string(el, CFRange(location: start, length: sel.location - start))
    }

    func isSettable(_ el: AXUIElement, _ attr: String) -> Bool {
        var ok = DarwinBoolean(false)
        return AXUIElementIsAttributeSettable(el, attr as CFString, &ok) == .success && ok.boolValue
    }

    let chromiumBrowsers: Set<String> = [
        "com.google.Chrome", "com.google.Chrome.beta", "com.google.Chrome.dev", "com.google.Chrome.canary",
        "org.chromium.Chromium", "com.brave.Browser", "com.microsoft.edgemac", "company.thebrowser.Browser",
        "com.vivaldi.Vivaldi", "com.operasoftware.Opera"
    ]
    var keystrokeAppCache: [String: Bool] = [:]

    /// Chrome-type browsers and Electron apps (Slack, Teams, WhatsApp, Discord…)
    func frontAppPrefersKeystrokes() -> Bool {
        guard let app = NSWorkspace.shared.frontmostApplication, let bid = app.bundleIdentifier else { return false }
        if let cached = keystrokeAppCache[bid] { return cached }
        var result = chromiumBrowsers.contains(bid)
        if !result, let url = app.bundleURL {
            let electron = url.appendingPathComponent("Contents/Frameworks/Electron Framework.framework").path
            result = FileManager.default.fileExists(atPath: electron)
        }
        keystrokeAppCache[bid] = result
        return result
    }

    /// For keystroke apps: only report a mismatch when the app clearly shows a *different* word there.
    /// If the app's text can't be read or is still catching up, go ahead.
    func wordVisiblyChanged(word: String, spacesAfter: Int, lastTyped: Character?) -> Bool {
        guard let el = focusedElement(), let sel = selectedRange(el), sel.length == 0 else { return false }
        let look = min(sel.location, 400)
        guard look > 0, let before = string(el, CFRange(location: sel.location - look, length: look)) else { return false }
        if let lastTyped, before.last != lastTyped { return false }
        let ns = before as NSString
        var end = ns.length
        var spaces = 0
        while spaces < spacesAfter && end > 0 {
            end -= 1
            if ns.character(at: end) == 0x20 { spaces += 1 }
        }
        let wl = (word as NSString).length
        guard spaces == spacesAfter, end >= wl else { return false }
        return ns.substring(with: NSRange(location: end - wl, length: wl)) != word
    }

    var forceKeystrokes: Bool {
        guard let dir = Bundle.main.object(forInfoDictionaryKey: "FixaroDevLogDir") as? String else { return false }
        return FileManager.default.fileExists(atPath: dir + "/force-keystrokes")
    }

    /// Swap `old` (the text right before the cursor) for `new` in one step, straight inside the app.
    /// .mismatch = the text isn't what we expected (e.g. the Mac's own autocorrect already changed it).
    func axReplace(old: String, new: String) -> Outcome {
        if forceKeystrokes || frontAppPrefersKeystrokes() { return .unsupported }
        guard let el = focusedElement(), let sel = selectedRange(el), sel.length == 0,
              isSettable(el, kAXSelectedTextRangeAttribute), isSettable(el, kAXSelectedTextAttribute) else { return .unsupported }
        let n = old.utf16.count
        guard sel.location >= n else {
            return string(el, CFRange(location: 0, length: sel.location)) == nil ? .unsupported : .mismatch
        }
        let start = sel.location - n
        guard let before = string(el, CFRange(location: start, length: n)) else { return .unsupported }
        guard before == old else { return .mismatch }
        guard setSelectedRange(el, CFRange(location: start, length: n)) else { return .unsupported }
        if AXUIElementSetAttributeValue(el, kAXSelectedTextAttribute as CFString, new as CFString) != .success {
            setSelectedRange(el, sel)
            return .unsupported
        }
        let m = new.utf16.count
        if let after = string(el, CFRange(location: start, length: m)), after != new {
            if string(el, CFRange(location: start, length: n)) == old {     // app ignored it
                setSelectedRange(el, sel)
                return .unsupported
            }
            logLine("note: in-place change gave an unexpected result")
        }
        if let now = selectedRange(el), now.location != start + m || now.length != 0 {
            setSelectedRange(el, CFRange(location: start + m, length: 0))
        }
        return .done
    }

    /// Find `word` in the app's text (it's followed by `spacesAfter` spaces up to the cursor) and swap it
    /// for `newWord`, straight inside the app. Words after it are left exactly as the app has them,
    /// so the Mac's own autocorrect changing a later word doesn't get in the way.
    func axReplaceWord(word: String, spacesAfter: Int, lastTyped: Character?, with newWord: String) -> Outcome {
        if forceKeystrokes { return .unsupported }
        guard let el = focusedElement(), let sel = selectedRange(el), sel.length == 0,
              isSettable(el, kAXSelectedTextRangeAttribute), isSettable(el, kAXSelectedTextAttribute) else { return .unsupported }
        let look = min(sel.location, 400)
        guard let before = string(el, CFRange(location: sel.location - look, length: look)) else { return .unsupported }
        // The app must already show the last key the user typed; if not, it's still catching up
        if let lastTyped, before.last != lastTyped { return .mismatch }
        let ns = before as NSString
        var end = ns.length
        var spaces = 0
        while spaces < spacesAfter && end > 0 {
            end -= 1
            if ns.character(at: end) == 0x20 { spaces += 1 }
        }
        guard spaces == spacesAfter else { return .mismatch }
        let wl = (word as NSString).length
        guard end >= wl, ns.substring(with: NSRange(location: end - wl, length: wl)) == word else { return .mismatch }
        if end - wl > 0, let prev = Unicode.Scalar(ns.character(at: end - wl - 1)),
           !CharacterSet.whitespacesAndNewlines.union(.punctuationCharacters).contains(prev) { return .mismatch }
        let start = sel.location - look + (end - wl)
        guard setSelectedRange(el, CFRange(location: start, length: wl)) else { return .unsupported }
        if AXUIElementSetAttributeValue(el, kAXSelectedTextAttribute as CFString, newWord as CFString) != .success {
            setSelectedRange(el, sel)
            return .unsupported
        }
        let nl = (newWord as NSString).length
        if let after = string(el, CFRange(location: start, length: nl)), after != newWord,
           string(el, CFRange(location: start, length: wl)) == word {        // app ignored the change
            setSelectedRange(el, sel)
            return .unsupported
        }
        if !setSelectedRange(el, CFRange(location: sel.location + nl - wl, length: 0)) {
            logLine("note: couldn't put the cursor back after a fix")
        }
        return .done
    }

    /// Fix a word: in place when the app supports it, otherwise Backspace + retype.
    /// `tail` is everything typed after the word (starting with its space, if any).
    func replaceWord(_ word: String, with newWord: String, tail: String) -> Outcome {
        let spaces = tail.filter { $0 == " " }.count
        if frontAppPrefersKeystrokes() {
            if wordVisiblyChanged(word: word, spacesAfter: spaces, lastTyped: (word + tail).last) { return .mismatch }
            sendKeys(backspaces: (word + tail).count, text: newWord + tail)
            return .done
        }
        let r = axReplaceWord(word: word, spacesAfter: spaces, lastTyped: (word + tail).last, with: newWord)
        if r == .done { lastMethod = "in place" }
        guard r == .unsupported else { return r }
        sendKeys(backspaces: (word + tail).count, text: newWord + tail)
        return .done
    }

    /// Swap the exact text `old` right before the cursor for `new` (used by undo).
    func replaceBeforeCursor(old: String, new: String) -> Outcome {
        let r = axReplace(old: old, new: new)
        if r == .done { lastMethod = "in place" }
        guard r == .unsupported else { return r }
        sendKeys(backspaces: old.count, text: new)
        return .done
    }

    /// Backspace + retype. The user's own keys are held back meanwhile, so nothing gets mixed in.
    func sendKeys(backspaces: Int, text: String) {
        lastMethod = "keystrokes"
        Typist.backspace(backspaces)
        Typist.type(text)
        scheduleHoldCheck()
    }

    // MARK: Holding the user's keys while Fixaro types

    var held: [(CGEventType, CGEvent)] = []
    var manualHold = false
    var manualHoldSince = Date.distantPast

    var isHolding: Bool { Typist.outstanding > 0 || manualHold }

    /// Safety valve: never hold keys for long, even if something goes wrong.
    func releaseIfStuck() {
        let now = Date()
        if manualHold && now.timeIntervalSince(manualHoldSince) > 1.0 {
            logLine("hold: Enter took too long; letting keys through")
            manualHold = false
        }
        if Typist.outstanding > 0 && now.timeIntervalSince(Typist.lastPost) > 0.35 {
            logLine("hold: \(Typist.outstanding) of Fixaro's keys never came back; letting keys through")
            Typist.outstanding = 0
        }
        if !isHolding { flushHeld() }
    }

    func scheduleHoldCheck() {
        Task {
            try? await Task.sleep(nanoseconds: 450_000_000)
            self.releaseIfStuck()
        }
    }

    /// Re-send the user's held keys, in order, as fresh events.
    func flushHeld() {
        guard !held.isEmpty else { return }
        let events = held
        held = []
        var n = 0
        for (t, e) in events {
            let kc = CGKeyCode(truncatingIfNeeded: e.getIntegerValueField(.keyboardEventKeycode))
            guard let r = CGEvent(keyboardEventSource: nil, virtualKey: kc, keyDown: t == .keyDown) else { continue }
            r.flags = e.flags
            var len = 0
            var buf = [UniChar](repeating: 0, count: 8)
            e.keyboardGetUnicodeString(maxStringLength: 8, actualStringLength: &len, unicodeString: &buf)
            if len > 0 { r.keyboardSetUnicodeString(stringLength: len, unicodeString: buf) }
            r.setIntegerValueField(.keyboardEventAutorepeat, value: e.getIntegerValueField(.keyboardEventAutorepeat))
            Typist.send(r, marker: kReplayMarker)
            if t == .keyDown { n += 1 }
        }
        if n > 0 { logLine("hold: re-sent \(n) key(s) typed while Fixaro was busy") }
        scheduleHoldCheck()
    }

    // MARK: Checking a word

    struct Analysis { let core: String; let trailing: String; let guesses: [String]; let fallback: String? }

    /// Is this token a misspelled English word worth fixing? Returns the spell checker's view of it.
    func analyze(_ token: String) -> Analysis? {
        let trailingSet: Set<Character> = [".", ",", "!", "?", ";", ":", ")", "\"", "”", "’", "'"]
        var core = token
        var trailing = ""
        while let last = core.last, trailingSet.contains(last) {
            trailing = String(last) + trailing
            core.removeLast()
        }
        guard core.count >= 3,
              let first = core.first, let lastCh = core.last,
              first.isLetter, lastCh.isLetter,
              core.allSatisfy({ $0.isLetter || $0 == "'" || $0 == "’" }) else { return nil }
        if hasNonLatinLetters(core) { return nil }                                // English only
        if core == core.uppercased() { return nil }                               // acronyms: NASA, PDF
        if core.dropFirst().contains(where: { $0.isUppercase }) { return nil }    // brand names: iPhone, GitHub
        let lower = core.lowercased()
        if wordList.contains(lower) || sessionIgnore.contains(lower) { return nil }

        let miss = checker.checkSpelling(of: core, startingAt: 0, language: "en", wrap: false,
                                         inSpellDocumentWithTag: spellTag, wordCount: nil)
        guard miss.location != NSNotFound else { return nil }
        let full = NSRange(location: 0, length: (core as NSString).length)
        let guesses = checker.guesses(forWordRange: full, in: core, language: "en", inSpellDocumentWithTag: spellTag) ?? []
        let fallback = checker.correction(forWordRange: full, in: core, language: "en", inSpellDocumentWithTag: spellTag)
        if guesses.isEmpty && fallback == nil { return nil }
        return Analysis(core: core, trailing: trailing, guesses: guesses, fallback: fallback)
    }

    func evaluate(token: String) {
        guard let a = analyze(token) else { return }
        nextID += 1
        let id = nextID
        let lead = String(String(context.dropLast(token.count + 1)).suffix(140))
        var p = PendingFix(id: id, core: a.core, trailing: a.trailing, tail: "", fallback: a.fallback,
                           guesses: a.guesses, lead: lead, asked: false)

        // A fix you've kept twice before: use it straight away
        if let lf = learned.fixes[a.core.lowercased()], lf.n >= 2, lf.mixed != true {
            p.asked = true
            pendings.append(p)
            Task { self.finish(id: id, choice: lf.to, source: "learned from you") }
            return
        }
        if activeEngine == .spell || a.guesses.isEmpty || pendings.count >= 4 {
            p.asked = true
            pendings.append(p)
            Task { self.finish(id: id, choice: a.fallback, source: "spell checker") }
            return
        }
        pendings.append(p)
        if !a.trailing.isEmpty { askAI(id); return }      // end of a clause: nothing more to wait for
        // Wait for the next word so the AI sees what comes after; ask anyway if you pause
        Task {
            try? await Task.sleep(nanoseconds: UInt64(kNextWordWait * 1_000_000_000))
            self.askAI(id)
        }
    }

    /// Ask the AI to pick the fix, now that it can see the words around the typo.
    func askAI(_ id: Int) {
        guard let idx = pendings.firstIndex(where: { $0.id == id }), !pendings[idx].asked else { return }
        pendings[idx].asked = true
        let p = pendings[idx]
        let after = String(p.tail.trimmingCharacters(in: .whitespaces).prefix(60))
        let wordsAround = p.lead.split(whereSeparator: { $0.isWhitespace }).count
            + after.split(whereSeparator: { $0.isWhitespace }).count
        if wordsAround < 2 && p.fallback != nil {          // hardly any context: trust the spell checker
            Task { self.finish(id: id, choice: p.fallback, source: "spell checker") }
            return
        }
        let engine = activeEngine
        let model = ollamaModel
        let core = p.core, guesses = p.guesses, fallback = p.fallback
        let prompt = makePrompt(word: core, before: p.lead,
                                after: p.trailing + (after.isEmpty ? "" : " " + after), guesses: guesses)
        let seen = after.isEmpty ? "" : ", saw next word"
        let started = Date()
        Task {
            var raw: String? = nil
            if engine == .apple {
                raw = await appleGenerate(prompt)
            } else if engine == .ollama, let model {
                raw = await Ollama.generate(model: model, system: systemFor(systemPrompt, model: model),
                                            prompt: prompt, numPredict: 24)
            }
            let picked = raw.flatMap { self.validate($0, original: core, guesses: guesses) }
            if picked == nil, let raw {
                logLine("AI reply for \(core) not used: \(raw.prefix(60).replacingOccurrences(of: "\n", with: " / "))")
            }
            let ms = Int(Date().timeIntervalSince(started) * 1000)
            self.finish(id: id, choice: picked ?? fallback,
                        source: picked != nil ? "\(self.engineLabel(engine)), \(ms) ms\(seen)" : "spell checker (LLM gave no usable answer)")
        }
        Task {
            try? await Task.sleep(nanoseconds: UInt64(kLLMTimeout * 1_000_000_000))
            self.finish(id: id, choice: fallback, source: "spell checker (LLM too slow)")
        }
    }

    func makePrompt(word: String, before: String, after: String, guesses: [String]) -> String {
        """
        Text: \(before)[\(word)]\(after)
        The word in brackets, "\(word)", is misspelled. Which word did the writer mean?
        Options: \(guesses.prefix(6).joined(separator: ", "))
        Answer with one word only.
        """
    }

    func validate(_ raw: String, original: String, guesses: [String]) -> String? {
        var s = raw
        if let r = s.range(of: "</think>") { s = String(s[r.upperBound...]) }
        s = s.trimmingCharacters(in: .whitespacesAndNewlines)
        if let firstLine = s.split(whereSeparator: \.isNewline).first { s = String(firstLine) }
        let strip = CharacterSet.punctuationCharacters.union(.symbols).union(.whitespaces)
        s = s.trimmingCharacters(in: strip)
        if let colon = s.lastIndex(of: ":") {
            s = String(s[s.index(after: colon)...]).trimmingCharacters(in: strip)
        }
        guard !s.isEmpty, s.lowercased() != original.lowercased() else { return nil }
        if guesses.contains(where: { $0.caseInsensitiveCompare(s) == .orderedSame }) { return s }
        guard !s.contains(" ") else { return nil }
        let spelledOK = checker.checkSpelling(of: s, startingAt: 0, language: "en", wrap: false,
                                              inSpellDocumentWithTag: spellTag, wordCount: nil).location == NSNotFound
        let close = editDistance(s.lowercased(), original.lowercased()) <= max(2, original.count / 3)
        return (spelledOK && close) ? s : nil
    }

    func finish(id: Int, choice: String?, source: String, attempt: Int = 0) {
        guard let idx = pendings.firstIndex(where: { $0.id == id }) else { return }
        releaseIfStuck()
        if isHolding {                            // Fixaro's own keystrokes still arriving: try again shortly
            Task {
                try? await Task.sleep(nanoseconds: 30_000_000)
                self.finish(id: id, choice: choice, source: source, attempt: attempt)
            }
            return
        }
        let p = pendings[idx]
        guard let choice, !choice.isEmpty else { pendings.remove(at: idx); return }
        let corrected = matchCase(choice, like: p.core)
        if corrected == p.core { pendings.remove(at: idx); return }
        if applyFix(p, corrected: corrected, source: source) == .mismatch {
            if attempt == 0 {
                Task {
                    try? await Task.sleep(nanoseconds: 40_000_000)
                    self.finish(id: id, choice: choice, source: source, attempt: 1)
                }
            } else {
                pendings.removeAll { $0.id == id }
                logLine("skip: \(p.core) (the text there changed; left it alone)")
            }
        }
    }

    func applyFix(_ p: PendingFix, corrected: String, source: String) -> Outcome {
        let oldSuffix = p.core + p.trailing + " " + p.tail
        let newSuffix = corrected + p.trailing + " " + p.tail
        let r = replaceWord(p.core + p.trailing, with: corrected + p.trailing, tail: " " + p.tail)
        if r == .mismatch { return r }
        pendings.removeAll { $0.id == p.id }
        if context.hasSuffix(oldSuffix) { context = String(context.dropLast(oldSuffix.count)) + newSuffix }
        // Earlier words still waiting for the AI contain this text, so keep their copy in sync
        for i in pendings.indices where pendings[i].tail.hasSuffix(oldSuffix) {
            pendings[i].tail = String(pendings[i].tail.dropLast(oldSuffix.count)) + newSuffix
        }
        for i in recentFixes.indices where recentFixes[i].tail.hasSuffix(oldSuffix) {
            recentFixes[i].tail = String(recentFixes[i].tail.dropLast(oldSuffix.count)) + newSuffix
        }
        recentFixes.append(RecentFix(original: p.core, corrected: corrected, trailing: p.trailing, tail: p.tail))
        if recentFixes.count > 5 { recordKept(recentFixes.removeFirst()) }
        undoArmed = p.tail.isEmpty
        lastFixText = "\(p.core) → \(corrected)"
        logLine("fix: \(p.core) → \(corrected)  [\(source), \(lastMethod)]")
        flashIcon()
        return .done
    }

    // MARK: Undo and learning from you

    /// Undo a recent fix. By Backspace (right after the fix) or by ⌃⌥Z (any time in the next 3 words).
    @discardableResult
    func undoFix(at index: Int, byBackspace: Bool) -> Bool {
        guard recentFixes.indices.contains(index) else { return false }
        let r = recentFixes[index]
        let fixedWord = r.corrected + r.trailing
        let oldSuffix: String
        let newSuffix: String
        let outcome: Outcome
        if byBackspace {                          // the Backspace also removes the space
            oldSuffix = fixedWord + " "
            newSuffix = r.original + r.trailing
            outcome = replaceBeforeCursor(old: oldSuffix, new: newSuffix)
        } else {
            oldSuffix = fixedWord + " " + r.tail
            newSuffix = r.original + r.trailing + " " + r.tail
            outcome = replaceWord(fixedWord, with: r.original + r.trailing, tail: " " + r.tail)
        }
        guard outcome == .done else { return false }
        recentFixes.remove(at: index)
        if context.hasSuffix(oldSuffix) { context = String(context.dropLast(oldSuffix.count)) + newSuffix }
        for i in pendings.indices where pendings[i].tail.hasSuffix(oldSuffix) {
            pendings[i].tail = String(pendings[i].tail.dropLast(oldSuffix.count)) + newSuffix
        }
        for i in recentFixes.indices where recentFixes[i].tail.hasSuffix(oldSuffix) {
            recentFixes[i].tail = String(recentFixes[i].tail.dropLast(oldSuffix.count)) + newSuffix
        }
        if byBackspace {
            word = newSuffix
            untrusted = false
        }
        sessionIgnore.insert(r.original.lowercased())
        lastUndone = r.original
        logLine("undo: \(r.corrected) → \(r.original)  [\(lastMethod)]")
        recordUndo(r.original)
        return true
    }

    func undoLastFixFromShortcut() async {
        await Typist.waitForModifierRelease(maxWait: 1.0)
        releaseIfStuck()
        guard !isHolding, !recentFixes.isEmpty else { NSSound.beep(); return }
        if !undoFix(at: recentFixes.count - 1, byBackspace: false) {
            NSSound.beep()
            logLine("undo: couldn't find the fixed word any more")
        }
    }

    /// Fixes followed by 3 more words count as kept.
    func settleRecentFixes() {
        let done = recentFixes.filter { $0.tail.filter { $0 == " " }.count >= 3 }
        guard !done.isEmpty else { return }
        recentFixes.removeAll { $0.tail.filter { $0 == " " }.count >= 3 }
        for r in done { recordKept(r) }
    }

    func commitRecentFixes() {
        let all = recentFixes
        recentFixes.removeAll()
        for r in all { recordKept(r) }
    }

    func recordKept(_ r: RecentFix) {
        let key = r.original.lowercased()
        let to = r.corrected.lowercased()
        var f = learned.fixes[key] ?? LearnedFix(to: to, n: 0, mixed: nil)
        if f.to != to { f = LearnedFix(to: to, n: 0, mixed: true) }   // depends on context: never instant
        f.n += 1
        learned.fixes[key] = f
        if f.n == 2 && f.mixed != true { logLine("learned: \(key) → \(to) (you kept it twice; now instant)") }
        saveLearned()
    }

    func recordUndo(_ original: String) {
        let key = original.lowercased()
        learned.fixes[key] = nil
        let n = (learned.undos[key] ?? 0) + 1
        learned.undos[key] = n
        if n >= 2 && !wordList.contains(key) {
            addToWordList(original)
            logLine("learned: never correct \(original) (you undid it twice)")
        }
        saveLearned()
    }

    var learnedURL: URL { wordListURL.deletingLastPathComponent().appendingPathComponent("learned.json") }

    func loadLearned() {
        guard let data = try? Data(contentsOf: learnedURL),
              let l = try? JSONDecoder().decode(Learned.self, from: data) else { return }
        learned = l
        if learned.version == nil {
            // Early builds made a typo instant even when its fix depends on context: start those over
            learned.fixes = [:]
            learned.version = 2
            saveLearned()
        }
    }

    func saveLearned() {
        let enc = JSONEncoder()
        enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        if let data = try? enc.encode(learned) { try? data.write(to: learnedURL, options: .atomic) }
    }

    // MARK: Rephrase (select text, press ⌃⌥R)

    struct RephraseStyle { let key: String; let title: String; let instruction: String }

    var rephrasing = false
    var lastRephraseText = "none yet"
    /// Your usual style: the one ⌃⌥R uses (ticked under Rephrase style)
    var rephraseStyle: String {
        get { defaults.string(forKey: "rephraseStyle") ?? "natural" }
        set { defaults.set(newValue, forKey: "rephraseStyle") }
    }
    let builtInStyles: [RephraseStyle] = [
        RephraseStyle(key: "natural", title: "Natural (same tone)", instruction: "Keep the same tone and roughly the same length, but make it read smoothly and naturally, the way a fluent native English writer would put it."),
        RephraseStyle(key: "professional", title: "Professional", instruction: "Make it sound polished and professional, suitable for a work email."),
        RephraseStyle(key: "shorter", title: "Shorter", instruction: "Make it noticeably shorter and more concise."),
        RephraseStyle(key: "friendly", title: "Friendly", instruction: "Make it warm and friendly.")
    ]

    var stylesURL: URL { wordListURL.deletingLastPathComponent().appendingPathComponent("styles.txt") }

    /// Your own styles, from styles.txt: one per line, "Name: how it should sound".
    func customStyles() -> [RephraseStyle] {
        guard let text = try? String(contentsOf: stylesURL, encoding: .utf8) else { return [] }
        var out: [RephraseStyle] = []
        var seen = Set<String>()
        for raw in text.split(whereSeparator: \.isNewline) {
            let line = raw.trimmingCharacters(in: .whitespaces)
            guard !line.hasPrefix("#"), let colon = line.firstIndex(of: ":") else { continue }
            let name = String(line[..<colon]).trimmingCharacters(in: .whitespaces)
            var how = String(line[line.index(after: colon)...]).trimmingCharacters(in: .whitespaces)
            guard !name.isEmpty, name.count <= 40, !how.isEmpty, !seen.contains(name.lowercased()) else { continue }
            if let last = how.last, !".!?".contains(last) { how += "." }
            seen.insert(name.lowercased())
            out.append(RephraseStyle(key: "custom:" + name, title: name, instruction: how))
        }
        return out
    }

    func allStyles() -> [RephraseStyle] { builtInStyles + customStyles() }

    func style(for key: String) -> RephraseStyle {
        allStyles().first { $0.key == key } ?? builtInStyles[0]
    }

    let stylesFileHeader = """
    # Your own rephrase styles, one per line:   Name: how it should sound
    # They appear when you press ⌃⌥S. Lines starting with # are ignored.
    #
    # Examples (remove the # at the start of a line to use it):
    # Board report: Formal, clear and concise, suitable for a board committee report.
    # Customer reply: Polite, warm and short, suitable for replying to a customer.
    # Simple English: Clear, simple English that is easy for non-native speakers to read.

    """

    func seedStylesFile() {
        if !FileManager.default.fileExists(atPath: stylesURL.path) {
            try? stylesFileHeader.write(to: stylesURL, atomically: true, encoding: .utf8)
        }
    }

    // MARK: The ⌃⌥S popup: pick a style, or type how to rewrite it

    enum RewriteChoice { case style(String), instruction(String) }

    /// A borderless panel that can take the keyboard without pulling the focus from the app you're writing in.
    final class PromptPanel: NSPanel {
        override var canBecomeKey: Bool { true }
    }

    var promptPanel: PromptPanel?
    var promptField: NSTextField?
    var promptStyles: [RephraseStyle] = []
    var promptUsual = "natural"
    var promptDone: ((RewriteChoice?) -> Void)?
    var promptReturnTo: NSRunningApplication?        // set only if Fixaro had to come forward to get the keyboard

    /// Shows the popup next to the selected text and waits for a choice. nil means cancelled.
    func showRewritePrompt() async -> RewriteChoice? {
        await withCheckedContinuation { (cont: CheckedContinuation<RewriteChoice?, Never>) in
            MainActor.assumeIsolated { openRewritePrompt { cont.resume(returning: $0) } }
        }
    }

    func openRewritePrompt(_ done: @escaping (RewriteChoice?) -> Void) {
        let styles = allStyles()
        promptStyles = styles
        promptUsual = styles.contains(where: { $0.key == rephraseStyle }) ? rephraseStyle : "natural"
        promptDone = done
        let inner: CGFloat = 316

        let field = NSTextField()
        field.placeholderString = "How should it be rewritten?"
        field.font = .systemFont(ofSize: 14)
        field.bezelStyle = .roundedBezel
        field.focusRingType = .none
        field.usesSingleLineMode = true
        field.cell?.isScrollable = true
        field.delegate = self
        field.translatesAutoresizingMaskIntoConstraints = false
        field.widthAnchor.constraint(equalToConstant: inner).isActive = true
        promptField = field

        let example = NSTextField(labelWithString: "For example: more formal, and ask for a reply by Sunday")
        example.font = .systemFont(ofSize: 11)
        example.textColor = .tertiaryLabelColor

        let header = NSTextField(labelWithString: "Or pick a style")
        header.font = .systemFont(ofSize: 11, weight: .semibold)
        header.textColor = .secondaryLabelColor

        var views: [NSView] = [field, example, header]
        for (i, st) in styles.enumerated() {
            let number = i < 9 ? "\(i + 1)" : " "
            let title = NSMutableAttributedString(string: "\(number)    ", attributes: [
                .font: NSFont.monospacedDigitSystemFont(ofSize: 12, weight: .regular),
                .foregroundColor: NSColor.tertiaryLabelColor])
            title.append(NSAttributedString(string: st.title, attributes: [
                .font: NSFont.systemFont(ofSize: 13), .foregroundColor: NSColor.labelColor]))
            if st.key == promptUsual {
                title.append(NSAttributedString(string: "   usual", attributes: [
                    .font: NSFont.systemFont(ofSize: 11), .foregroundColor: NSColor.tertiaryLabelColor]))
            }
            let b = NSButton(title: st.title, target: self, action: #selector(promptPickedStyle(_:)))
            b.attributedTitle = title
            b.tag = i
            b.bezelStyle = .recessed
            b.showsBorderOnlyWhileMouseInside = true
            b.alignment = .left
            b.translatesAutoresizingMaskIntoConstraints = false
            b.widthAnchor.constraint(equalToConstant: inner).isActive = true
            views.append(b)
        }
        let foot = NSTextField(labelWithString: "Return rewrites  ·  Esc cancels")
        foot.font = .systemFont(ofSize: 11)
        foot.textColor = .tertiaryLabelColor
        views.append(foot)

        let stack = NSStackView(views: views)
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 2
        stack.setCustomSpacing(5, after: field)
        stack.setCustomSpacing(12, after: example)
        stack.setCustomSpacing(4, after: header)
        if let last = views.dropLast().last { stack.setCustomSpacing(8, after: last) }
        stack.edgeInsets = NSEdgeInsets(top: 12, left: 12, bottom: 10, right: 12)
        stack.translatesAutoresizingMaskIntoConstraints = false

        let fx = NSVisualEffectView()
        fx.material = .popover
        fx.state = .active
        fx.wantsLayer = true
        fx.layer?.cornerRadius = 10
        fx.layer?.masksToBounds = true
        fx.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: fx.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: fx.trailingAnchor),
            stack.topAnchor.constraint(equalTo: fx.topAnchor),
            stack.bottomAnchor.constraint(equalTo: fx.bottomAnchor),
        ])

        let panel = PromptPanel(contentRect: NSRect(x: 0, y: 0, width: 340, height: 200),
                                styleMask: [.nonactivatingPanel, .borderless], backing: .buffered, defer: false)
        panel.isFloatingPanel = true
        panel.level = .popUpMenu
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = true
        panel.hidesOnDeactivate = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient]
        panel.contentView = fx
        panel.delegate = self
        promptPanel = panel

        // Next to the selected text, kept on the screen
        let size = fx.fittingSize
        let p = selectionPoint() ?? NSPoint(x: NSEvent.mouseLocation.x, y: NSEvent.mouseLocation.y - 8)
        let screen = NSScreen.screens.first { $0.frame.contains(p) } ?? NSScreen.main
        var frame = NSRect(x: p.x, y: p.y - size.height, width: size.width, height: size.height)
        if let vf = screen?.visibleFrame {
            frame.origin.x = min(max(frame.minX, vf.minX + 8), vf.maxX - frame.width - 8)
            if frame.minY < vf.minY + 8 { frame.origin.y = min(p.y + 28, vf.maxY - frame.height - 8) }
        }
        panel.setFrame(frame, display: true)
        panel.makeKeyAndOrderFront(nil)
        panel.makeFirstResponder(field)
        if !panel.isKeyWindow {                      // some setups won't let a background app take the keyboard
            promptReturnTo = NSWorkspace.shared.frontmostApplication
            NSApp.activate(ignoringOtherApps: true)
            panel.makeKeyAndOrderFront(nil)
            panel.makeFirstResponder(field)
        }
    }

    func finishPrompt(_ choice: RewriteChoice?) {
        guard let done = promptDone else { return }
        promptDone = nil
        promptPanel?.delegate = nil
        promptPanel?.orderOut(nil)
        promptPanel = nil
        promptField = nil
        if let back = promptReturnTo {               // hand the focus back to the app you were writing in
            promptReturnTo = nil
            if back.bundleIdentifier != Bundle.main.bundleIdentifier { back.activate(options: []) }
        }
        done(choice)
    }

    @objc func promptPickedStyle(_ sender: NSButton) {
        guard sender.tag < promptStyles.count else { return }
        finishPrompt(.style(promptStyles[sender.tag].key))
    }

    /// In the box: Return rewrites (your words, or your usual style if it's empty); Esc cancels.
    func control(_ control: NSControl, textView: NSTextView, doCommandBy sel: Selector) -> Bool {
        guard control === promptField else { return false }
        if sel == #selector(NSResponder.insertNewline(_:)) {
            let t = (promptField?.stringValue ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            finishPrompt(t.isEmpty ? .style(promptUsual) : .instruction(t))
            return true
        }
        if sel == #selector(NSResponder.cancelOperation(_:)) {
            finishPrompt(nil)
            return true
        }
        return false
    }

    /// A number typed into the empty box picks that style straight away.
    func controlTextDidChange(_ note: Notification) {
        guard let f = promptField, (note.object as? NSTextField) === f else { return }
        let t = f.stringValue
        if t.count == 1, let n = Int(t), n >= 1, n <= min(9, promptStyles.count) {
            finishPrompt(.style(promptStyles[n - 1].key))
        }
    }

    /// Clicking anywhere else closes the popup.
    func windowDidResignKey(_ note: Notification) {
        if let w = note.object as? NSWindow, w === promptPanel { finishPrompt(nil) }
    }

    /// Just below the selected text, so the popup opens next to it (nil if the app can't say where it is).
    func selectionPoint() -> NSPoint? {
        guard let el = focusedElement() else { return nil }
        var rangeRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(el, kAXSelectedTextRangeAttribute as CFString, &rangeRef) == .success,
              let rangeRef else { return nil }
        var boundsRef: CFTypeRef?
        guard AXUIElementCopyParameterizedAttributeValue(el, kAXBoundsForRangeParameterizedAttribute as CFString,
                                                         rangeRef, &boundsRef) == .success,
              let boundsRef, CFGetTypeID(boundsRef) == AXValueGetTypeID() else { return nil }
        var r = CGRect.zero
        guard AXValueGetValue(boundsRef as! AXValue, .cgRect, &r), r.height > 0 else { return nil }
        let top = NSScreen.screens.first?.frame.maxY ?? 0           // Accessibility measures from the top of the main screen
        let p = NSPoint(x: r.minX, y: top - r.maxY - 4)
        return NSScreen.screens.contains { $0.frame.contains(p) } ? p : nil
    }

    @objc func addStyle() {
        let previous = NSWorkspace.shared.frontmostApplication
        defer {                                                       // hand the focus back to the app you were in
            if let previous, previous.bundleIdentifier != Bundle.main.bundleIdentifier { previous.activate(options: []) }
        }
        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.messageText = "Add a rephrase style"
        alert.informativeText = "Give it a short name, and describe how your text should sound. It will appear when you press ⌃⌥S."
        let name = NSTextField(frame: NSRect(x: 0, y: 34, width: 360, height: 24))
        name.placeholderString = "Name, for example: Board report"
        let how = NSTextField(frame: NSRect(x: 0, y: 0, width: 360, height: 24))
        how.placeholderString = "How it should sound: formal and concise, for a board report"
        name.nextKeyView = how
        how.nextKeyView = name
        let box = NSView(frame: NSRect(x: 0, y: 0, width: 360, height: 58))
        box.addSubview(name)
        box.addSubview(how)
        alert.accessoryView = box
        alert.addButton(withTitle: "Add")
        alert.addButton(withTitle: "Cancel")
        alert.window.initialFirstResponder = name
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        let n = String(name.stringValue.replacingOccurrences(of: ":", with: " -")
            .trimmingCharacters(in: .whitespacesAndNewlines).prefix(40))
        let h = how.stringValue.replacingOccurrences(of: "\n", with: " ").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !n.isEmpty, !h.isEmpty else { NSSound.beep(); return }
        seedStylesFile()
        var lines = ((try? String(contentsOf: stylesURL, encoding: .utf8)) ?? "").components(separatedBy: "\n")
        lines.removeAll { l in                                       // a style with the same name is replaced
            guard !l.hasPrefix("#"), let c = l.firstIndex(of: ":") else { return false }
            return l[..<c].trimmingCharacters(in: .whitespaces).lowercased() == n.lowercased()
        }
        while lines.last?.isEmpty == true { lines.removeLast() }
        lines.append("\(n): \(h)")
        try? (lines.joined(separator: "\n") + "\n").write(to: stylesURL, atomically: true, encoding: .utf8)
        logLine("rephrase: added style “\(n)”")
    }

    @objc func editStyles() {
        seedStylesFile()
        NSWorkspace.shared.open(stylesURL)
    }

    func rephraseSelection(choose: Bool) async {
        guard !rephrasing else { return }
        let useApple = appleOK
        let rephraseModel: String? = ollamaModels.isEmpty ? nil : (rephraseModelSetting ?? ollamaModel)
        guard useApple || rephraseModel != nil else {
            NSSound.beep()
            showBubble("Start Ollama first, then try again", busy: false, near: nil)
            hideBubble(after: 3)
            lastRephraseText = "needs Ollama running"
            logLine("rephrase: no AI engine available")
            return
        }
        rephrasing = true
        logLine("rephrase: \(choose ? "⌃⌥S" : "⌃⌥R") pressed in \(NSWorkspace.shared.frontmostApplication?.localizedName ?? "?")")
        updateIcon(symbol: "ellipsis.circle")
        defer { rephrasing = false; updateIcon() }

        // Copy the selection without losing what was on the clipboard
        let pb = NSPasteboard.general
        let saved = savePasteboard(pb)
        await Typist.waitForModifierRelease()
        try? await Task.sleep(nanoseconds: 50_000_000)
        pb.clearContents()
        let before = pb.changeCount
        Typist.combo(8, .maskCommand)                                   // ⌘C
        var text: String? = nil
        for _ in 0..<50 {
            try? await Task.sleep(nanoseconds: 20_000_000)
            if pb.changeCount != before { text = pb.string(forType: .string); break }
        }
        guard let original = text, !original.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            restorePasteboard(pb, saved)
            NSSound.beep()
            showBubble("Select some text first, then try again", busy: false, near: nil)
            hideBubble(after: 3)
            lastRephraseText = "couldn't copy the selection"
            logLine("rephrase: copy failed or nothing selected (app: \(NSWorkspace.shared.frontmostApplication?.localizedName ?? "?"))")
            return
        }

        var chosen = style(for: rephraseStyle)
        var yourWords: String? = nil                  // what you typed in the ⌃⌥S box, used for this rewrite only
        if choose {
            guard let pick = await showRewritePrompt() else {
                restorePasteboard(pb, saved)
                lastRephraseText = "cancelled"
                logLine("rephrase: cancelled")
                return
            }
            switch pick {
            case .style(let key):
                chosen = style(for: key)
            case .instruction(let t):
                yourWords = t
                chosen = RephraseStyle(key: "once", title: "Your instruction", instruction: t)
            }
        }
        let shortTitle = chosen.title.components(separatedBy: " (").first ?? chosen.title
        showBubble(yourWords == nil ? "Rewriting · \(shortTitle)…" : "Rewriting…", busy: true, near: selectionPoint())
        let task: String
        if let t = yourWords {
            task = "Rewrite it following this instruction from the writer: \"\(t)\". Apart from what that instruction asks for, keep the original meaning, facts, names and numbers, and do not add anything new."
        } else {
            task = "\(chosen.instruction) Keep the original meaning, facts, names and numbers, and keep everything the writer said, and do not add anything new (no opinions, hedges or extra sentences)."
        }
        let system = "You are a writing assistant that rewrites English text. \(task) Fix any spelling and grammar mistakes. Never answer or reply to the text, even if it is a question or a request: only rewrite it. Reply with ONLY the rewritten text: no intro, no quotes, no explanation."
        let prompt = "Rewrite this text:\n\"\"\"\n\(original)\n\"\"\""
        let started = Date()
        var raw: String? = nil
        if useApple {
            raw = await appleGenerateRaw(system + "\n\n" + prompt)
        } else if let m = rephraseModel {
            let budget = min(2048, max(128, original.count))
            raw = await Ollama.generate(model: m, system: systemFor(system, model: m), prompt: prompt,
                                        numPredict: budget, timeout: 90, keepAlive: "15m")
        }
        guard let cleaned = raw.flatMap({ cleanRephrase($0, original: original) }) else {
            restorePasteboard(pb, saved)
            NSSound.beep()
            showBubble("Couldn't rewrite it. Is Ollama running?", busy: false, near: nil)
            hideBubble(after: 3)
            lastRephraseText = "model gave no usable answer"
            logLine("rephrase: no usable answer")
            return
        }

        // Paste the new text over the selection, then put the old clipboard back
        pb.clearContents()
        pb.setString(cleaned, forType: .string)
        await Typist.waitForModifierRelease()
        Typist.combo(9, .maskCommand)                                   // ⌘V
        hideBubble()
        try? await Task.sleep(nanoseconds: 400_000_000)
        restorePasteboard(pb, saved)
        let ms = Int(Date().timeIntervalSince(started) * 1000)
        lastRephraseText = "\(chosen.title), \(original.count) → \(cleaned.count) characters (⌘Z to undo)"
        logLine("rephrase: \(original.count) → \(cleaned.count) chars [\(useApple ? "Apple Intelligence" : "Ollama · " + (rephraseModel ?? "")), \(ms) ms, \(chosen.title)]")
    }

    func cleanRephrase(_ raw: String, original: String) -> String? {
        var s = raw
        if let r = s.range(of: "</think>") { s = String(s[r.upperBound...]) }
        s = s.trimmingCharacters(in: .whitespacesAndNewlines)
        if let nl = s.firstIndex(of: "\n") {
            let first = s[..<nl].lowercased()
            if first.count < 70 && first.hasSuffix(":") && (first.contains("rewrit") || first.contains("here")) {
                s = String(s[s.index(after: nl)...]).trimmingCharacters(in: .whitespacesAndNewlines)
            }
        }
        if s.hasPrefix("\"\"\"") { s = String(s.dropFirst(3)) }
        if s.hasSuffix("\"\"\"") { s = String(s.dropLast(3)) }
        s = s.trimmingCharacters(in: .whitespacesAndNewlines)
        if !original.hasPrefix("\""), s.count > 1,
           (s.hasPrefix("\"") && s.hasSuffix("\"")) || (s.hasPrefix("“") && s.hasSuffix("”")) {
            s = String(s.dropFirst().dropLast())
        }
        guard !s.isEmpty, s.count <= original.count * 4 + 100 else { return nil }
        let trailingWS = String(Array(original.reversed().prefix(while: { $0.isWhitespace })).reversed())
        return s + trailingWS
    }

    func savePasteboard(_ pb: NSPasteboard) -> [[(NSPasteboard.PasteboardType, Data)]] {
        (pb.pasteboardItems ?? []).map { item in
            item.types.compactMap { t in item.data(forType: t).map { (t, $0) } }
        }
    }

    func restorePasteboard(_ pb: NSPasteboard, _ saved: [[(NSPasteboard.PasteboardType, Data)]]) {
        pb.clearContents()
        let items: [NSPasteboardItem] = saved.map { pairs in
            let it = NSPasteboardItem()
            for (t, d) in pairs { it.setData(d, forType: t) }
            return it
        }
        if !items.isEmpty { pb.writeObjects(items) }
    }

    // MARK: Word list

    /// Early builds were called "AutoFix": carry over their word list and learned fixes once.
    func migrateEarlyData() {
        let fm = FileManager.default
        let base = fm.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support")
        let old = base.appendingPathComponent("AutoFix"), new = base.appendingPathComponent("Fixaro")
        if !fm.fileExists(atPath: new.path) && fm.fileExists(atPath: old.path) {
            try? fm.copyItem(at: old, to: new)
        }
    }

    func setupWordList() {
        if !FileManager.default.fileExists(atPath: wordListURL.path) {
            let seed = """
            # Fixaro word list: one word per line. These words are never corrected.
            # Add names, work terms and slang here. Changes are picked up within 10 seconds.
            Fixaro
            Ollama
            Qwen
            Gemma
            """
            try? seed.write(to: wordListURL, atomically: true, encoding: .utf8)
        }
        reloadWordList(force: true)
    }

    func reloadWordList(force: Bool = false) {
        let m = (try? FileManager.default.attributesOfItem(atPath: wordListURL.path))?[.modificationDate] as? Date
        if !force && m == wordListMTime { return }
        wordListMTime = m
        let text = (try? String(contentsOf: wordListURL, encoding: .utf8)) ?? ""
        wordList = Set(text.split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty && !$0.hasPrefix("#") }
            .map { $0.lowercased() })
    }

    func addToWordList(_ w: String) {
        var text = (try? String(contentsOf: wordListURL, encoding: .utf8)) ?? ""
        if !text.hasSuffix("\n") { text += "\n" }
        text += w + "\n"
        try? text.write(to: wordListURL, atomically: true, encoding: .utf8)
        reloadWordList(force: true)
    }

    // MARK: Menu bar

    func updateIcon(symbol: String? = nil) {
        let name = symbol ?? (tap == nil ? "exclamationmark.triangle" : (enabled ? "logo" : "pause.circle"))
        // The Fixaro "F" when all is well; system symbols for paused, busy or needing permission
        let img = name == "logo" ? (Bundle.main.image(forResource: "MenuIcon") ?? NSImage(systemSymbolName: "text.badge.checkmark", accessibilityDescription: "Fixaro"))
                                 : NSImage(systemSymbolName: name, accessibilityDescription: "Fixaro")
        img?.isTemplate = true
        statusItem?.button?.image = img
    }

    func flashIcon() {
        updateIcon(symbol: "sparkles")
        Task {
            try? await Task.sleep(nanoseconds: 700_000_000)
            self.updateIcon()
        }
    }

    func item(_ title: String, _ sel: Selector?) -> NSMenuItem {
        let i = NSMenuItem(title: title, action: sel, keyEquivalent: "")
        i.target = self
        return i
    }

    func label(_ title: String) -> NSMenuItem {
        let i = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        i.isEnabled = false
        return i
    }

    func symbol(_ name: String) -> NSImage? {
        NSImage(systemSymbolName: name, accessibilityDescription: nil)
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        reloadWordList()
        if Date().timeIntervalSince(lastModelRefresh) > 5 { Task { await self.refreshModelList() } }
        menu.removeAllItems()
        let ready = AXIsProcessTrusted() && tap != nil

        // Name and state
        let state = !ready ? "needs permission" : (!enabled ? "paused" : (fixTyping ? "on · fixing typos" : "on"))
        let head = NSMutableAttributedString(string: "Fixaro", attributes: [.font: NSFont.boldSystemFont(ofSize: 13)])
        head.append(NSAttributedString(string: "  \(state)", attributes: [.font: NSFont.systemFont(ofSize: 13),
                                                                          .foregroundColor: NSColor.secondaryLabelColor]))
        let header = NSMenuItem(title: "Fixaro \(state)", action: nil, keyEquivalent: "")
        header.attributedTitle = head
        header.isEnabled = false
        menu.addItem(header)
        if !ready {
            let allow = item("Allow Fixaro in Accessibility…", #selector(showWelcome))
            allow.image = symbol("exclamationmark.triangle")
            menu.addItem(allow)
        }
        menu.addItem(.separator())

        // Rephrase
        let reph = item("Rephrase selected text", #selector(rephraseFromMenu))
        reph.keyEquivalent = "r"
        reph.keyEquivalentModifierMask = [.control, .option]
        reph.image = symbol("wand.and.stars")
        menu.addItem(reph)
        let rephAs = item("Rephrase as…", #selector(rephraseChooseFromMenu))
        rephAs.keyEquivalent = "s"
        rephAs.keyEquivalentModifierMask = [.control, .option]
        menu.addItem(rephAs)
        menu.addItem(styleMenuItem())

        // Typos
        let ft = item("Fix typos as I type", #selector(toggleFixTyping))
        ft.state = fixTyping ? .on : .off
        menu.addItem(ft)
        if fixTyping {
            let undo = item("Undo last fix", #selector(undoFromMenu))
            undo.keyEquivalent = "z"
            undo.keyEquivalentModifierMask = [.control, .option]
            menu.addItem(undo)
        }
        if let u = lastUndone {
            menu.addItem(item("Never correct “\(u)”", #selector(addLastUndone)))
        }
        if let front = NSWorkspace.shared.frontmostApplication, let bid = front.bundleIdentifier,
           bid != Bundle.main.bundleIdentifier {
            let name = front.localizedName ?? bid
            let it = item(excludedApps.contains(bid) ? "Turn on in \(name)" : "Turn off in \(name)", #selector(toggleApp(_:)))
            it.representedObject = bid
            menu.addItem(it)
        }
        menu.addItem(.separator())

        // What happened last
        if fixTyping { menu.addItem(label("Last fix: \(lastFixText)")) }
        menu.addItem(label("Last rephrase: \(lastRephraseText)"))
        menu.addItem(.separator())

        let settings = NSMenuItem(title: "Settings", action: nil, keyEquivalent: "")
        settings.image = symbol("gearshape")
        settings.submenu = settingsMenu()
        menu.addItem(settings)
        let pause = item(enabled ? "Pause Fixaro" : "Resume Fixaro", #selector(toggleEnabled))
        pause.image = symbol(enabled ? "pause.circle" : "play.circle")
        menu.addItem(pause)
        let q = item("Quit Fixaro", #selector(quit))
        q.keyEquivalent = "q"
        menu.addItem(q)
    }

    /// Your usual style (the one ⌃⌥R uses); add and edit your own.
    func styleMenuItem() -> NSMenuItem {
        let sm = NSMenu()
        sm.addItem(NSMenuItem.sectionHeader(title: "⌃⌥R uses"))
        for (i, s) in allStyles().enumerated() {
            if i == builtInStyles.count { sm.addItem(.separator()) }
            let it = item(s.title, #selector(selectStyle(_:)))
            it.representedObject = s.key
            it.state = rephraseStyle == s.key ? .on : .off
            sm.addItem(it)
        }
        sm.addItem(.separator())
        sm.addItem(item("Add a style…", #selector(addStyle)))
        sm.addItem(item("Edit my styles…", #selector(editStyles)))
        let title = "Rephrase style: \(style(for: rephraseStyle).title)"
        let si = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        si.submenu = sm
        return si
    }

    /// Everything you set once: models, AI app, apps, word list, startup.
    func settingsMenu() -> NSMenu {
        let menu = NSMenu()
        menu.autoenablesItems = false

        menu.addItem(NSMenuItem.sectionHeader(title: "AI"))
        if !ollamaModels.isEmpty {
            let mm = NSMenu()
            for m in ollamaModels {
                let gbText = String(format: "%.1f GB", Double(m.size) / 1e9)
                let it = item("\(m.name)  (\(gbText))", #selector(selectModel(_:)))
                it.representedObject = m.name
                it.state = m.name == ollamaModel ? .on : .off
                mm.addItem(it)
            }
            let mi = NSMenuItem(title: "Word-fix model: \(ollamaModel ?? "none")", action: nil, keyEquivalent: "")
            mi.submenu = mm
            menu.addItem(mi)

            let rm = NSMenu()
            for m in ollamaModels {
                let gbText = String(format: "%.1f GB", Double(m.size) / 1e9)
                let it = item("\(m.name)  (\(gbText))", #selector(selectRephraseModel(_:)))
                it.representedObject = m.name
                it.state = m.name == rephraseModelSetting ? .on : .off
                rm.addItem(it)
            }
            let ri = NSMenuItem(title: "Rephrase model: \(rephraseModelSetting ?? "none")", action: nil, keyEquivalent: "")
            ri.submenu = rm
            menu.addItem(ri)
        } else {
            menu.addItem(label("No models found. Is \(Ollama.displayName) running?"))
        }
        if serverKind == .ollama {
            if let s = downloadStatus { menu.addItem(label(s)) }
            else { menu.addItem(item("Download a model…", #selector(downloadModel))) }
        }
        // Where the AI runs: Ollama, or another local AI app
        let serverMenu = NSMenu()
        let presets: [(String, ServerKind, String)] = [
            ("Ollama", .ollama, "http://127.0.0.1:11434"),
            ("LM Studio (localhost:1234)", .openai, "http://localhost:1234/v1"),
            ("llama.cpp or MLX server (localhost:8080)", .openai, "http://localhost:8080/v1"),
            ("Jan (localhost:1337)", .openai, "http://localhost:1337/v1"),
        ]
        for (title, kind, url) in presets {
            let it = item(title, #selector(selectServer(_:)))
            it.representedObject = [kind.rawValue, url]
            it.state = (serverKind == kind && serverURL == url) ? .on : .off
            serverMenu.addItem(it)
        }
        let isPreset = presets.contains { $0.1 == serverKind && $0.2 == serverURL }
        let other = item(isPreset ? "Other app (OpenAI-compatible)…" : "Other: \(serverURL)…", #selector(enterServerURL))
        other.state = isPreset ? .off : .on
        serverMenu.addItem(other)
        let serverItem = NSMenuItem(title: "AI app: \(Ollama.displayName)", action: nil, keyEquivalent: "")
        serverItem.submenu = serverMenu
        menu.addItem(serverItem)

        let engineMenu = NSMenu()
        engineMenu.autoenablesItems = false
        let choices: [(EngineChoice, String, Bool)] = [
            (.auto, "Auto (best available)", true),
            (.apple, "Apple Intelligence" + (appleOK ? "" : " (not available)"), appleOK),
            (.ollama, Ollama.displayName + (ollamaModels.isEmpty ? " (not running)" : ""), !ollamaModels.isEmpty),
            (.spell, "Spell checker only (fastest)", true)
        ]
        for (c, title, ok) in choices {
            let it = item(title, #selector(selectEngine(_:)))
            it.representedObject = c.rawValue
            it.state = engineChoice == c ? .on : .off
            it.isEnabled = ok
            engineMenu.addItem(it)
        }
        let engineItem = NSMenuItem(title: "Typo engine: \(engineLabel(activeEngine))", action: nil, keyEquivalent: "")
        engineItem.submenu = engineMenu
        menu.addItem(engineItem)
        menu.addItem(item("Refresh models", #selector(refreshEnginesAction)))
        menu.addItem(.separator())

        menu.addItem(NSMenuItem.sectionHeader(title: "Typing"))
        menu.addItem(appsMenuItem())
        menu.addItem(item("Edit word list…", #selector(editWordList)))
        let kept = learned.fixes.values.filter { $0.n >= 2 && $0.mixed != true }.count
        let never = learned.undos.values.filter { $0 >= 2 }.count
        menu.addItem(label("Learned: \(kept) instant fixes · \(never) words left alone"))
        if !learned.fixes.isEmpty {
            menu.addItem(item("Forget learned fixes", #selector(forgetLearned)))
        }
        menu.addItem(.separator())

        menu.addItem(item("Welcome and shortcuts…", #selector(showWelcome)))
        let login = item("Start at login", #selector(toggleLogin))
        login.state = SMAppService.mainApp.status == .enabled ? .on : .off
        menu.addItem(login)
        menu.addItem(item("Open log", #selector(openLog)))
        return menu
    }

    @objc func rephraseFromMenu() { Task { await self.rephraseSelection(choose: false) } }
    @objc func rephraseChooseFromMenu() { Task { await self.rephraseSelection(choose: true) } }
    @objc func undoFromMenu() { Task { await self.undoLastFixFromShortcut() } }

    // MARK: Welcome window

    var welcomed: Bool {
        get { defaults.bool(forKey: "welcomed") }
        set { defaults.set(newValue, forKey: "welcomed") }
    }
    var welcomeWindow: NSWindow?
    var welcomeTimer: Timer?
    var welcomeAXIcon = NSImageView()
    var welcomeAXDetail = NSTextField(wrappingLabelWithString: "")
    var welcomeAXButton = NSButton()
    var welcomeAIIcon = NSImageView()
    var welcomeAIDetail = NSTextField(wrappingLabelWithString: "")
    var welcomeAIButton = NSButton()

    @objc func showWelcome() {
        NSApp.activate(ignoringOtherApps: true)
        if let w = welcomeWindow { w.makeKeyAndOrderFront(nil); return }

        let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 480, height: 400),
                         styleMask: [.titled, .closable], backing: .buffered, defer: false)
        w.title = "Welcome to Fixaro"
        w.isReleasedWhenClosed = false

        let icon = NSImageView(image: NSApp.applicationIconImage)
        icon.translatesAutoresizingMaskIntoConstraints = false
        icon.widthAnchor.constraint(equalToConstant: 64).isActive = true
        icon.heightAnchor.constraint(equalToConstant: 64).isActive = true
        let name = NSTextField(labelWithString: "Fixaro")
        name.font = .systemFont(ofSize: 24, weight: .bold)
        let tagline = NSTextField(wrappingLabelWithString: "Fixes the grammar of the text you select and rewrites it, with an AI that runs on this Mac. Nothing you write leaves your computer.")
        tagline.textColor = .secondaryLabelColor
        tagline.preferredMaxLayoutWidth = 340
        let titles = NSStackView(views: [name, tagline])
        titles.orientation = .vertical
        titles.alignment = .leading
        titles.spacing = 4
        let top = NSStackView(views: [icon, titles])
        top.alignment = .top
        top.spacing = 16

        welcomeAXButton = NSButton(title: "Allow…", target: self, action: #selector(welcomeAllow))
        welcomeAIButton = NSButton(title: "Get Ollama", target: self, action: #selector(welcomeGetOllama))
        let step1 = welcomeRow(icon: welcomeAXIcon, title: "1. Allow Accessibility", detail: welcomeAXDetail, button: welcomeAXButton)
        let step2 = welcomeRow(icon: welcomeAIIcon, title: "2. An AI model on your Mac", detail: welcomeAIDetail, button: welcomeAIButton)

        let keys = NSTextField(labelWithString: "Shortcuts")
        keys.font = .boldSystemFont(ofSize: 13)
        let k1 = NSTextField(labelWithString: "⌃⌥R    Rephrase the selected text in your usual style")
        let k3 = NSTextField(labelWithString: "⌃⌥S    Pick a style, or type how to rewrite it")
        let k2 = NSTextField(labelWithString: "Typo fixing as you type is off. Turn it on in the menu: Fix typos as I type")
        for k in [k1, k3, k2] { k.font = .systemFont(ofSize: 12); k.textColor = .secondaryLabelColor }
        let shortcuts = NSStackView(views: [keys, k1, k3, k2])
        shortcuts.orientation = .vertical
        shortcuts.alignment = .leading
        shortcuts.spacing = 4

        let done = NSButton(title: "Done", target: self, action: #selector(welcomeDone))
        done.keyEquivalent = "\r"
        done.setContentHuggingPriority(.required, for: .horizontal)
        let spacer = NSView()
        let bottom = NSStackView(views: [spacer, done])
        bottom.distribution = .fill

        let stack = NSStackView(views: [top, step1, step2, shortcuts, bottom])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 18
        stack.edgeInsets = NSEdgeInsets(top: 22, left: 24, bottom: 20, right: 24)
        stack.translatesAutoresizingMaskIntoConstraints = false
        bottom.translatesAutoresizingMaskIntoConstraints = false
        let content = NSView()
        content.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            stack.topAnchor.constraint(equalTo: content.topAnchor),
            stack.bottomAnchor.constraint(equalTo: content.bottomAnchor),
            content.widthAnchor.constraint(equalToConstant: 480),
            bottom.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -48),
        ])
        w.contentView = content
        w.setContentSize(content.fittingSize)
        w.center()
        welcomeWindow = w
        refreshWelcome()
        w.makeKeyAndOrderFront(nil)

        welcomeTimer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.refreshWelcome() }
        }
        NotificationCenter.default.addObserver(forName: NSWindow.willCloseNotification, object: w, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.welcomeTimer?.invalidate()
                self.welcomeTimer = nil
                self.welcomeWindow = nil
                self.welcomed = true
            }
        }
    }

    func welcomeRow(icon: NSImageView, title: String, detail: NSTextField, button: NSButton) -> NSView {
        icon.translatesAutoresizingMaskIntoConstraints = false
        icon.widthAnchor.constraint(equalToConstant: 20).isActive = true
        icon.heightAnchor.constraint(equalToConstant: 20).isActive = true
        let t = NSTextField(labelWithString: title)
        t.font = .boldSystemFont(ofSize: 13)
        detail.font = .systemFont(ofSize: 12)
        detail.textColor = .secondaryLabelColor
        detail.preferredMaxLayoutWidth = 290
        let texts = NSStackView(views: [t, detail])
        texts.orientation = .vertical
        texts.alignment = .leading
        texts.spacing = 2
        let row = NSStackView(views: [icon, texts, button])
        row.alignment = .top
        row.spacing = 10
        return row
    }

    func setWelcomeStatus(_ view: NSImageView, ok: Bool, warn: Bool = false) {
        let name = ok ? "checkmark.circle.fill" : (warn ? "exclamationmark.circle.fill" : "circle.dashed")
        view.image = NSImage(systemSymbolName: name, accessibilityDescription: ok ? "done" : "to do")
        view.contentTintColor = ok ? .systemGreen : (warn ? .systemOrange : .secondaryLabelColor)
    }

    func refreshWelcome() {
        let ax = AXIsProcessTrusted()
        setWelcomeStatus(welcomeAXIcon, ok: ax)
        welcomeAXButton.isHidden = ax
        welcomeAXDetail.stringValue = ax
            ? "Done. Fixaro can now fix and rewrite text in your apps."
            : "Lets Fixaro read and replace text in other apps. Click Allow…, then turn Fixaro on in the list."
        if Date().timeIntervalSince(lastModelRefresh) > 3 { Task { await self.refreshModelList() } }
        let ai = !ollamaModels.isEmpty || appleOK
        setWelcomeStatus(welcomeAIIcon, ok: ai, warn: !ai && downloadStatus == nil)
        let rec = recommendedModel()
        if !ollamaModels.isEmpty {
            welcomeAIButton.isHidden = true
            welcomeAIDetail.stringValue = "\(Ollama.displayName) is running. Typos: \(ollamaModel ?? "none") · Rephrasing: \(rephraseModelSetting ?? ollamaModel ?? "none")"
        } else if appleOK {
            welcomeAIButton.isHidden = true
            welcomeAIDetail.stringValue = "Using Apple Intelligence on this Mac."
        } else if let status = downloadStatus {
            welcomeAIButton.isHidden = true
            welcomeAIDetail.stringValue = status
        } else if aiReachable {
            welcomeAIButton.isHidden = false
            welcomeAIButton.title = "Download"
            welcomeAIButton.action = #selector(welcomeDownloadModel)
            welcomeAIDetail.stringValue = "Ollama is running. Download \(rec.name) (\(rec.size)), the best fit for this Mac's memory."
        } else {
            welcomeAIButton.isHidden = false
            welcomeAIButton.title = "Get Ollama"
            welcomeAIButton.action = #selector(welcomeGetOllama)
            welcomeAIDetail.stringValue = "Install Ollama (free) and open it. Fixaro finds it within seconds and offers a model to download."
        }
    }

    @objc func welcomeAllow() {
        let opts = ["AXTrustedCheckOptionPrompt": true] as CFDictionary
        if !AXIsProcessTrustedWithOptions(opts) { openAXSettings() }
    }

    @objc func welcomeGetOllama() {
        if let url = URL(string: "https://ollama.com/download") { NSWorkspace.shared.open(url) }
    }

    @objc func welcomeDownloadModel() { startDownload(recommendedModel().name) }

    @objc func welcomeDone() {
        welcomed = true
        welcomeWindow?.close()
    }

    // MARK: The small "Rewriting…" bubble

    var bubble: NSPanel?
    let bubbleLabel = NSTextField(labelWithString: "")
    let bubbleSpinner = NSProgressIndicator()
    var bubbleGen = 0

    /// A small floating note next to your text. It never takes the focus or the mouse.
    func showBubble(_ text: String, busy: Bool, near point: NSPoint?) {
        bubbleGen += 1
        let panel: NSPanel
        if let b = bubble {
            panel = b
        } else {
            panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 180, height: 32),
                            styleMask: [.nonactivatingPanel, .borderless], backing: .buffered, defer: true)
            panel.isFloatingPanel = true
            panel.level = .popUpMenu
            panel.backgroundColor = .clear
            panel.isOpaque = false
            panel.hasShadow = true
            panel.ignoresMouseEvents = true
            panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient]
            let fx = NSVisualEffectView()
            fx.material = .popover
            fx.state = .active
            fx.wantsLayer = true
            fx.layer?.cornerRadius = 9
            fx.layer?.masksToBounds = true
            bubbleSpinner.style = .spinning
            bubbleSpinner.controlSize = .small
            bubbleSpinner.isIndeterminate = true
            bubbleLabel.font = .systemFont(ofSize: 12, weight: .medium)
            let row = NSStackView(views: [bubbleSpinner, bubbleLabel])
            row.spacing = 7
            row.edgeInsets = NSEdgeInsets(top: 7, left: 11, bottom: 7, right: 13)
            row.translatesAutoresizingMaskIntoConstraints = false
            fx.addSubview(row)
            NSLayoutConstraint.activate([
                row.leadingAnchor.constraint(equalTo: fx.leadingAnchor),
                row.trailingAnchor.constraint(equalTo: fx.trailingAnchor),
                row.topAnchor.constraint(equalTo: fx.topAnchor),
                row.bottomAnchor.constraint(equalTo: fx.bottomAnchor),
            ])
            panel.contentView = fx
            bubble = panel
        }
        bubbleLabel.stringValue = text
        bubbleSpinner.isHidden = !busy
        if busy { bubbleSpinner.startAnimation(nil) } else { bubbleSpinner.stopAnimation(nil) }
        let size = panel.contentView?.fittingSize ?? NSSize(width: 180, height: 32)
        let p = point ?? NSPoint(x: NSEvent.mouseLocation.x + 12, y: NSEvent.mouseLocation.y - 12)
        panel.setFrame(NSRect(x: p.x, y: p.y - size.height, width: size.width, height: size.height), display: true)
        panel.orderFrontRegardless()
    }

    /// Hide the bubble now, or after a moment (unless a newer one has appeared since).
    func hideBubble(after seconds: Double = 0) {
        let gen = bubbleGen
        guard seconds > 0 else { bubble?.orderOut(nil); bubbleSpinner.stopAnimation(nil); return }
        Task {
            try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
            if self.bubbleGen == gen { self.bubble?.orderOut(nil) }
        }
    }

    @objc func toggleEnabled() { enabled.toggle(); reset() }
    @objc func toggleFixTyping() {
        fixTyping.toggle()
        reset()
        logLine(fixTyping ? "Typo fixing on" : "Typo fixing off")
        if fixTyping { Task { await self.warmUp() } }
    }
    @objc func selectStyle(_ sender: NSMenuItem) {
        if let k = sender.representedObject as? String { rephraseStyle = k }
    }
    @objc func openAXSettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") {
            NSWorkspace.shared.open(url)
        }
    }
    @objc func selectEngine(_ sender: NSMenuItem) {
        guard let r = sender.representedObject as? String, let c = EngineChoice(rawValue: r) else { return }
        engineChoice = c
        logLine("Engine set to \(c.rawValue) · using \(engineLabel(activeEngine))")
        Task { await self.warmUp() }
    }
    @objc func selectModel(_ sender: NSMenuItem) {
        ollamaModel = sender.representedObject as? String
        resolveEngine()
        logLine("Ollama model set to \(ollamaModel ?? "none")")
        Task { await self.warmUp() }
    }
    @objc func selectRephraseModel(_ sender: NSMenuItem) {
        rephraseModelSetting = sender.representedObject as? String
        logLine("Rephrase model set to \(rephraseModelSetting ?? "none")")
    }
    @objc func refreshEnginesAction() { Task { await self.refreshEngines() } }

    // MARK: Choosing the AI app and downloading models

    @objc func selectServer(_ sender: NSMenuItem) {
        guard let v = sender.representedObject as? [String], v.count == 2, let k = ServerKind(rawValue: v[0]) else { return }
        applyServer(kind: k, url: v[1])
    }

    @objc func enterServerURL() {
        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.messageText = "Use another AI app"
        alert.informativeText = "Enter the address of a local AI app with an OpenAI-compatible API, for example LM Studio: http://localhost:1234/v1\n\nThe app must be running with a model loaded."
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 320, height: 24))
        field.stringValue = serverKind == .openai ? serverURL : "http://localhost:1234/v1"
        alert.accessoryView = field
        alert.addButton(withTitle: "Use It")
        alert.addButton(withTitle: "Cancel")
        alert.window.initialFirstResponder = field
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        var url = field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        while url.hasSuffix("/") { url.removeLast() }
        guard let u = URL(string: url), let scheme = u.scheme, ["http", "https"].contains(scheme), let host = u.host else {
            NSSound.beep()
            return
        }
        let onThisMac = ["localhost", "127.0.0.1", "::1"].contains(host)
        if !onThisMac {
            let warn = NSAlert()
            warn.messageText = "Your text would leave this Mac"
            warn.informativeText = "\(host) is not this Mac. Every word Fixaro checks and every text you rephrase would be sent there. Only continue if you trust that computer."
            warn.addButton(withTitle: "Continue")
            warn.addButton(withTitle: "Cancel")
            guard warn.runModal() == .alertFirstButtonReturn else { return }
        }
        applyServer(kind: .openai, url: url)
    }

    func applyServer(kind: ServerKind, url: String) {
        serverKind = kind
        serverURL = url
        Ollama.kind = kind
        Ollama.base = url
        ollamaModels = []
        logLine("AI app set to \(Ollama.displayName) (\(url))")
        Task { await self.refreshEngines() }
    }

    @objc func downloadModel() {
        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.messageText = "Download a model"
        alert.informativeText = "Type a model name from ollama.com/library, for example qwen3.5:4b or llama3.2:3b.\n\nBig models take a while. You can keep working; the menu shows the progress."
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 320, height: 24))
        field.placeholderString = "qwen3.5:4b"
        alert.accessoryView = field
        alert.addButton(withTitle: "Download")
        alert.addButton(withTitle: "Cancel")
        alert.window.initialFirstResponder = field
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        let name = field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty, !name.contains(" ") else { NSSound.beep(); return }
        startDownload(name)
    }

    func startDownload(_ name: String) {
        guard downloadStatus == nil else { return }
        downloadStatus = "Downloading \(name)…"
        logLine("download: \(name) started")
        Task {
            let ok = await Ollama.pull(name) { status in self.downloadStatus = "Downloading \(name)… \(status)" }
            self.downloadStatus = nil
            logLine(ok ? "download: \(name) finished" : "download: \(name) failed (check the name on ollama.com/library)")
            if !ok { NSSound.beep() }
            await self.refreshModelList()
        }
    }

    /// The model to start with, by this Mac's memory (tested in tools/bench.py).
    func recommendedModel() -> (name: String, size: String) {
        let gb = Double(ProcessInfo.processInfo.physicalMemory) / 1_073_741_824
        return gb >= 15 ? ("qwen3.5:4b", "4 GB") : ("nemotron-3-nano:4b", "2.9 GB")
    }

    // MARK: Turning Fixaro off in specific apps

    /// "Off in these apps" submenu: every open app plus every app already turned off. A checkmark = Fixaro is off there.
    func appsMenuItem() -> NSMenuItem {
        var apps: [(name: String, bid: String)] = []
        var seen = Set<String>()
        for app in NSWorkspace.shared.runningApplications where app.activationPolicy == .regular {
            guard let bid = app.bundleIdentifier, bid != Bundle.main.bundleIdentifier, !seen.contains(bid) else { continue }
            seen.insert(bid)
            apps.append((app.localizedName ?? bid, bid))
        }
        for bid in excludedApps where !seen.contains(bid) {
            seen.insert(bid)
            var name = bid
            if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bid) {
                name = FileManager.default.displayName(atPath: url.path).replacingOccurrences(of: ".app", with: "")
            } else {
                continue                                   // not installed: nothing to show
            }
            apps.append((name, bid))
        }
        apps.sort { a, b in
            let ao = excludedApps.contains(a.bid), bo = excludedApps.contains(b.bid)
            if ao != bo { return ao }
            return a.name.localizedCaseInsensitiveCompare(b.name) == .orderedAscending
        }
        let sub = NSMenu()
        sub.addItem(label("Checked apps: Fixaro stays off"))
        for a in apps {
            let it = item(a.name, #selector(toggleApp(_:)))
            it.representedObject = a.bid
            it.state = excludedApps.contains(a.bid) ? .on : .off
            if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: a.bid) {
                let icon = NSWorkspace.shared.icon(forFile: url.path)
                icon.size = NSSize(width: 16, height: 16)
                it.image = icon
            }
            sub.addItem(it)
        }
        let off = excludedApps.count
        let mi = NSMenuItem(title: off == 0 ? "Turn off in apps" : "Turned off in \(off) app\(off == 1 ? "" : "s")",
                            action: nil, keyEquivalent: "")
        mi.submenu = sub
        return mi
    }
    @objc func forgetLearned() {
        learned.fixes = [:]
        saveLearned()
        logLine("learned fixes cleared")
    }
    @objc func addLastUndone() {
        guard let u = lastUndone else { return }
        addToWordList(u)
        lastUndone = nil
    }
    @objc func editWordList() { NSWorkspace.shared.open(wordListURL) }
    @objc func toggleApp(_ sender: NSMenuItem) {
        guard let bid = sender.representedObject as? String else { return }
        if excludedApps.contains(bid) { excludedApps.remove(bid) } else { excludedApps.insert(bid) }
        logLine(excludedApps.contains(bid) ? "turned off in \(bid)" : "turned on in \(bid)")
        reset()
    }
    @objc func toggleLogin() {
        do {
            if SMAppService.mainApp.status == .enabled { try SMAppService.mainApp.unregister() }
            else { try SMAppService.mainApp.register() }
        } catch {
            logLine("Start at login error: \(error)")
        }
    }
    @objc func openLog() { NSWorkspace.shared.open(logURL) }
    @objc func quit() { NSApp.terminate(nil) }
}

// MARK: - Entry point

MainActor.assumeIsolated {
    let app = NSApplication.shared
    let delegate = AppDelegate()
    app.delegate = delegate
    app.setActivationPolicy(.accessory)
    withExtendedLifetime(delegate) { app.run() }
}

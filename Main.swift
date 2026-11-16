import AppKit
import SwiftUI
import AVFoundation

struct Voice: Decodable, Identifiable { let id: Int; let name: String }
struct ReaderError: LocalizedError { var message: String; var errorDescription: String? { message } }

func chunks(_ text: String) -> [String] {
    var result: [String] = [], current = ""
    for c in text {
        current.append(c)
        if current.count >= 180 || (current.count >= 24 && "。！？!?\n".contains(c)) {
            if !current.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { result.append(current) }
            current = ""
        }
    }
    if !current.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { result.append(current) }
    return result
}

// A private pipe avoids opening a server or sharing RTranslate's port.
final class Engine: @unchecked Sendable {
    private let queue = DispatchQueue(label: "RSpeech.engine")
    private var process: Process?
    private var input: FileHandle?
    private var output: FileHandle?
    private var buffer = Data()
    private let lock = NSLock()
    private var canceled = false

    func close() {
        lock.lock(); canceled = true; let p = process; lock.unlock()
        if p?.isRunning == true { p?.terminate() }
    }
    private func line() throws -> Data {
        while true {
            if let end = buffer.firstIndex(of: 10) {
                let data = Data(buffer[..<end]); buffer.removeSubrange(...end); return data
            }
            guard let data = output?.availableData, !data.isEmpty else {
                throw ReaderError(message: "VOICEVOXが終了しました。もう一度 ▶ を押してください。")
            }
            buffer.append(data)
        }
    }
    func start() async throws -> [Voice] {
        try await withCheckedThrowingContinuation { continuation in
            queue.async {
                do {
                    let configURL = Bundle.main.url(forResource: "runtime", withExtension: "json")!
                    let config = try JSONSerialization.jsonObject(with: Data(contentsOf: configURL)) as! [String: String]
                    let resources = Bundle.main.resourceURL!
                    let python = resources.appendingPathComponent(config["python"]!).path
                    let shared = URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Library/Application Support/RTranslate/Assets/voicevox").path
                    let sharedComplete = ["models/vvms/0.vvm", "models/vvms/1.vvm", "models/vvms/12.vvm", "dict"].allSatisfy { FileManager.default.fileExists(atPath: shared + "/" + $0) }
                    let root = sharedComplete && !CommandLine.arguments.contains("--bundled-model-test") ? shared : resources.appendingPathComponent("voicevox").path
                    let runtime = resources.appendingPathComponent(config["runtime"]!).path
                    guard FileManager.default.isExecutableFile(atPath: python),
                          FileManager.default.fileExists(atPath: root + "/models/vvms/0.vvm") else {
                        throw ReaderError(message: "音声データが見つかりません。RSpeech.appをフォルダごとコピーし直してください。")
                    }
                    let p = Process(), stdinPipe = Pipe(), stdoutPipe = Pipe()
                    p.executableURL = URL(fileURLWithPath: python)
                    p.arguments = ["-B", "-u", Bundle.main.path(forResource: "worker", ofType: "py")!, root, runtime]
                    p.environment = ["PATH": "/usr/bin:/bin", "HOME": NSHomeDirectory(), "TMPDIR": NSTemporaryDirectory(), "PYTHONNOUSERSITE": "1", "PYTHONDONTWRITEBYTECODE": "1"]
                    p.standardInput = stdinPipe; p.standardOutput = stdoutPipe; p.standardError = FileHandle.nullDevice
                    self.input = stdinPipe.fileHandleForWriting; self.output = stdoutPipe.fileHandleForReading
                    self.lock.lock()
                    if self.canceled { self.lock.unlock(); throw CancellationError() }
                    do { try p.run(); self.process = p; self.lock.unlock() } catch { self.lock.unlock(); throw error }
                    let reply = try JSONSerialization.jsonObject(with: self.line()) as! [String: Any]
                    let voices = try JSONDecoder().decode([Voice].self, from: JSONSerialization.data(withJSONObject: reply["voices"]!))
                    continuation.resume(returning: voices)
                } catch { continuation.resume(throwing: error) }
            }
        }
    }
    func synthesize(_ text: String, speaker: Int, speed: Double) async throws -> Data {
        try await withCheckedThrowingContinuation { continuation in
            queue.async {
                do {
                    var request = try JSONSerialization.data(withJSONObject: ["text": text, "speaker": speaker, "speed": speed])
                    request.append(10); try self.input?.write(contentsOf: request)
                    let reply = try JSONSerialization.jsonObject(with: self.line()) as! [String: Any]
                    guard let wav = reply["wav"] as? String, let data = Data(base64Encoded: wav) else {
                        throw ReaderError(message: reply["error"] as? String ?? "音声を生成できませんでした。")
                    }
                    continuation.resume(returning: data)
                } catch { continuation.resume(throwing: error) }
            }
        }
    }
    deinit { close() }
}

struct Page: Codable, Sendable { let url: String; let text: String }
protocol SafariSource: Sendable {
    func currentURL() async throws -> String
    func page() async throws -> Page
}
struct SafariSourceLive: SafariSource {
    private func execute(_ source: String) async throws -> String {
        try await Task.detached {
            var error: NSDictionary?
            guard let script = NSAppleScript(source: source) else { throw ReaderError(message: "Safariの取得処理を作成できませんでした。") }
            let reply = script.executeAndReturnError(&error)
            if let error {
                let number = error[NSAppleScript.errorNumber] as? Int ?? 0
                if number == -1743 { throw ReaderError(message: "システム設定 → プライバシーとセキュリティ → オートメーションで、RSpeechによるSafariの操作を許可してください。") }
                if number == -1728 { throw ReaderError(message: "SafariでWebページを開いてください。") }
                throw ReaderError(message: "Safariから取得できませんでした。Safariの開発メニューで「Apple EventsからのJavaScriptを許可」を確認してください。")
            }
            return reply.stringValue ?? ""
        }.value
    }
    func currentURL() async throws -> String {
        let url = try await execute("tell application \"Safari\" to get URL of current tab of front window")
        guard !url.isEmpty else { throw ReaderError(message: "SafariでWebページを開いてください。") }
        return url
    }
    func page() async throws -> Page {
        let javascript = try String(contentsOf: Bundle.main.url(forResource: "PageExtraction", withExtension: "js")!, encoding: .utf8)
        let escaped = javascript.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"")
        let json = try await execute("tell application \"Safari\" to do JavaScript \"\(escaped)\" in current tab of front window")
        guard let data = json.data(using: .utf8), let page = try? JSONDecoder().decode(Page.self, from: data) else {
            throw ReaderError(message: "ページの本文を取得できませんでした。")
        }
        return page
    }
}
protocol SpeechEngine: AnyObject, Sendable {
    func start() async throws -> [Voice]
    func synthesize(_ text: String, speaker: Int, speed: Double) async throws -> Data
    func close()
}
extension Engine: SpeechEngine {}

@MainActor final class Reader: ObservableObject {
    @Published private(set) var text = ""
    @Published private(set) var pageURL: String?
    @Published var status = "Safariでページを開いて ▶ を押してください。"
    @Published var voices: [Voice] = []
    @Published var expanded = false
    @Published var speaker = UserDefaults.standard.object(forKey: "speaker") as? Int ?? 2
    @Published var speed = UserDefaults.standard.object(forKey: "speed") as? Double ?? 1.2
    @Published private(set) var busy = false
    @Published private(set) var paused = false
    @Published private(set) var fetching = false
    var buttonSymbol: String { busy && !paused ? "pause.fill" : "play.fill" }
    var buttonLabel: String { busy && !paused ? "一時停止" : (paused ? "再開" : "再生") }
    private let safari: any SafariSource
    private let makeEngine: () -> any SpeechEngine
    private let muted: Bool
    private var engine: (any SpeechEngine)?
    private var task: Task<Void, Never>?
    private var player: AVAudioPlayer?
    private var audioStarted = false
    private var generation = UUID()
    private var fetchGeneration = UUID()

    init(safari: any SafariSource = SafariSourceLive(), muted: Bool = false, makeEngine: @escaping () -> any SpeechEngine = { Engine() }) {
        self.safari = safari; self.muted = muted; self.makeEngine = makeEngine
    }
    func toggle() {
        guard !fetching else { return }
        if busy && !paused {
            paused = true; player?.pause(); status = "一時停止中"; return
        }
        fetching = true; let request = UUID(); fetchGeneration = request
        Task {
            defer { if fetchGeneration == request { fetching = false } }
            do {
                let url = try await safari.currentURL()
                guard fetchGeneration == request else { return }
                if url != pageURL || text.isEmpty {
                    // Clear the old page before fetching; a failed fetch must not resume old speech.
                    stopPlayback(); text = ""; pageURL = nil
                    status = "Safariから本文を取得中…"
                    let page = try await safari.page()
                    guard fetchGeneration == request else { return }
                    // The tab may have navigated while JavaScript was extracting the page.
                    guard try await safari.currentURL() == page.url else {
                        throw ReaderError(message: "取得中にページが切り替わりました。もう一度 ▶ を押してください。")
                    }
                    guard fetchGeneration == request else { return }
                    guard !page.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                        throw ReaderError(message: "読み上げられる本文がありません。")
                    }
                    text = page.text; pageURL = page.url
                }
                guard fetchGeneration == request else { return }
                if busy && paused {
                    paused = false
                    if audioStarted { player?.play() }
                    status = "読み上げ中"
                } else { read() }
            } catch {
                guard fetchGeneration == request else { return }
                status = error.localizedDescription
            }
        }
    }
    private func read() {
        guard !busy else { return }
        let parts = chunks(text)
        guard !parts.isEmpty else { return }
        busy = true; paused = false; generation = UUID(); let id = generation
        UserDefaults.standard.set(speaker, forKey: "speaker"); UserDefaults.standard.set(speed, forKey: "speed")
        task = Task {
            do {
                if engine == nil {
                    status = "VOICEVOXを準備中…"
                    let e = makeEngine(); engine = e
                    let loaded = try await e.start()
                    guard generation == id else { return }
                    voices = loaded
                    if !voices.contains(where: { $0.id == speaker }) { speaker = 2 }
                }
                guard let e = engine else { return }
                for (index, part) in parts.enumerated() {
                    guard generation == id, !Task.isCancelled else { return }
                    status = paused ? "一時停止中" : "音声を準備中 \(index + 1) / \(parts.count)"
                    let data = try await e.synthesize(part, speaker: speaker, speed: speed)
                    guard generation == id, !Task.isCancelled else { return }
                    let audio = try AVAudioPlayer(data: data); player = audio; audioStarted = false
                    if muted { audio.volume = 0 }
                    audio.prepareToPlay()
                    while paused { try await Task.sleep(nanoseconds: 50_000_000) }
                    guard generation == id, !Task.isCancelled else { return }
                    guard audio.play() else { throw ReaderError(message: "音声を再生できませんでした。Macの出力先を確認してください。") }
                    audioStarted = true
                    status = "読み上げ中 \(index + 1) / \(parts.count)"
                    while audio.isPlaying || paused { try await Task.sleep(nanoseconds: 50_000_000) }
                    player = nil; audioStarted = false
                }
                busy = false; paused = false; status = "読み上げが終わりました。"
            } catch {
                guard generation == id else { return }
                stopPlayback(); status = error.localizedDescription
            }
        }
    }
    private func stopPlayback() {
        generation = UUID(); task?.cancel(); task = nil
        player?.stop(); player = nil; audioStarted = false
        engine?.close(); engine = nil; busy = false; paused = false
    }
    func stop() {
        fetchGeneration = UUID(); fetching = false
        stopPlayback(); status = "停止しました。"
    }
}

struct ContentView: View {
    @ObservedObject var reader: Reader
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 16) {
                Button { reader.toggle() } label: {
                    Image(systemName: reader.buttonSymbol).font(.system(size: 22)).frame(width: 34, height: 34)
                }.buttonStyle(.borderedProminent).accessibilityLabel(reader.buttonLabel)
                    .keyboardShortcut(.return, modifiers: .command).disabled(reader.fetching)
                Picker("声", selection: $reader.speaker) {
                    if reader.voices.isEmpty {
                        Text("四国めたん").tag(2); Text("ずんだもん").tag(3); Text("春日部つむぎ").tag(8)
                        Text("雨晴はう").tag(10); Text("冥鳴ひまり").tag(14); Text("雀松朱司").tag(52)
                    } else { ForEach(reader.voices) { Text($0.name).tag($0.id) } }
                }.frame(width: 190).disabled(reader.busy || reader.fetching)
                Picker("速度", selection: $reader.speed) {
                    ForEach([0.75, 1.0, 1.2, 1.5, 1.75, 2.0], id: \.self) { Text(String(format: "%.2g倍", $0)).tag($0) }
                }.frame(width: 135).disabled(reader.busy || reader.fetching)
            }
            Text(reader.status).font(.callout).foregroundStyle(.secondary).textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
            DisclosureGroup("取得した本文（\(reader.text.count)文字）", isExpanded: $reader.expanded) {
                ScrollView { Text(reader.text.isEmpty ? "本文はまだ取得していません。" : reader.text).frame(maxWidth: .infinity, alignment: .leading).textSelection(.enabled).padding(8) }
                    .frame(height: 250).background(Color(nsColor: .textBackgroundColor)).cornerRadius(5)
            }
            Text("VOICEVOX:\(reader.voices.first(where: { $0.id == reader.speaker })?.name ?? [2:"四国めたん", 3:"ずんだもん", 8:"春日部つむぎ", 10:"雨晴はう", 14:"冥鳴ひまり", 52:"雀松朱司"][reader.speaker] ?? "四国めたん")").font(.caption).foregroundStyle(.secondary)
        }.padding(18).frame(width: 530)
    }
}

@MainActor final class AppDelegate: NSObject, NSApplicationDelegate {
    let reader = Reader()
    var window: NSWindow!
    var item: NSStatusItem!
    func applicationDidFinishLaunching(_ notification: Notification) {
        let mainMenu = NSMenu()
        let appMenuItem = NSMenuItem(); let appMenu = NSMenu()
        appMenu.addItem(withTitle: "RSpeechを終了", action: #selector(quit), keyEquivalent: "q").target = self
        appMenuItem.submenu = appMenu; mainMenu.addItem(appMenuItem)
        let editItem = NSMenuItem(); let editMenu = NSMenu(title: "編集")
        editMenu.addItem(withTitle: "取り消す", action: Selector(("undo:")), keyEquivalent: "z")
        editMenu.addItem(.separator())
        editMenu.addItem(withTitle: "カット", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        editMenu.addItem(withTitle: "コピー", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        editMenu.addItem(withTitle: "ペースト", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        editMenu.addItem(withTitle: "すべてを選択", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        editItem.submenu = editMenu; mainMenu.addItem(editItem); NSApp.mainMenu = mainMenu
        window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 566, height: 190), styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false)
        window.title = "RSpeech"; window.isReleasedWhenClosed = false
        window.contentView = NSHostingView(rootView: ContentView(reader: reader)); window.center(); show()
        item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        item.button?.image = NSImage(systemSymbolName: "speaker.wave.2", accessibilityDescription: "RSpeech")
        let menu = NSMenu()
        menu.addItem(withTitle: "ウインドウを開く", action: #selector(show), keyEquivalent: "").target = self
        menu.addItem(withTitle: "再生 / 一時停止", action: #selector(fetch), keyEquivalent: "").target = self
        menu.addItem(withTitle: "読み上げを停止", action: #selector(stop), keyEquivalent: "").target = self
        menu.addItem(.separator())
        menu.addItem(withTitle: "終了", action: #selector(quit), keyEquivalent: "q").target = self
        item.menu = menu
    }
    @objc func show() { NSApp.activate(ignoringOtherApps: true); window.makeKeyAndOrderFront(nil) }
    @objc func fetch() { show(); reader.toggle() }
    @objc func stop() { reader.stop() }
    @objc func quit() { NSApp.terminate(nil) }
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool { show(); return true }
    func applicationWillTerminate(_ notification: Notification) { reader.stop() }
}

if CommandLine.arguments.contains("--self-test") {
    let text = "日本語とSafari、APIを同じ声で読みます。\n" + String(repeating: "長文です。", count: 200)
    let parts = chunks(text)
    precondition(parts.joined() == text)
    precondition(parts.allSatisfy { $0.count <= 180 })
    precondition(chunks(" \n\t").isEmpty)
    print("Text chunk checks passed")
} else if CommandLine.arguments.contains("--audio-self-test") {
    MainActor.assumeIsolated {
        Task { @MainActor in
            let engine = Engine()
            do {
                let voices = try await engine.start()
                precondition(voices.count == 6)
                for speaker in [2, 14, 52, 2] {
                    let wav = try await engine.synthesize("SafariのWebページとAPIを同じ声で読みます。", speaker: speaker, speed: 1.5)
                    let audio = try AVAudioPlayer(data: wav)
                    precondition(audio.duration > 0)
                    if speaker == 2 {
                        audio.volume = 0
                        precondition(audio.play())
                        while audio.isPlaying { try await Task.sleep(nanoseconds: 100_000_000) }
                    }
                }
                engine.close()
                print("6 voices discovered; mixed Japanese/English synthesis, model switching, muted playback passed")
                exit(0)
            } catch {
                engine.close(); print("Audio integration check failed: \(error.localizedDescription)"); exit(1)
            }
        }
        RunLoop.main.run()
    }
} else {
    MainActor.assumeIsolated {
        let app = NSApplication.shared
        let delegate = AppDelegate(); app.delegate = delegate; app.setActivationPolicy(.regular); app.run()
    }
}

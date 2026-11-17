import AppKit
import SwiftUI
import AVFoundation

struct Voice: Decodable, Identifiable { let id: Int; let name: String }
struct ReaderError: LocalizedError { var message: String; var errorDescription: String? { message } }

// Resolve against the logged-in account, not the account used to build the app.
func voicevoxModelRoot(home: URL) -> URL {
    home.appendingPathComponent("Library/Application Support/RTranslate/Assets/voicevox", isDirectory: true)
}
func validateVoicevoxModels(at root: URL) throws {
    let files = ["models/vvms/0.vvm", "models/vvms/1.vvm", "models/vvms/12.vvm"]
    let dictionary = root.appendingPathComponent("dict")
    let dictionaries = (try? FileManager.default.contentsOfDirectory(at: dictionary, includingPropertiesForKeys: nil)) ?? []
    let hasDictionary = dictionaries.contains {
        $0.lastPathComponent.hasPrefix("open_jtalk_dic") && FileManager.default.fileExists(atPath: $0.appendingPathComponent("sys.dic").path)
    }
    guard hasDictionary && files.allSatisfy({ FileManager.default.fileExists(atPath: root.appendingPathComponent($0).path) }) else {
        throw ReaderError(message: "RTranslateのVOICEVOXデータが見つかりません。R翻訳で音声データを準備してください。\n参照先：\(root.path)")
    }
}

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
                    let root = voicevoxModelRoot(home: FileManager.default.homeDirectoryForCurrentUser).path
                    let runtime = resources.appendingPathComponent(config["runtime"]!).path
                    try validateVoicevoxModels(at: URL(fileURLWithPath: root))
                    guard FileManager.default.isExecutableFile(atPath: python) else {
                        throw ReaderError(message: "音声実行環境が見つかりません。RSpeechを入れ直してください。")
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
    func synthesize(_ text: String, speaker: Int, speed: Double, dictionary: [ReadingEntry]) async throws -> Data {
        try await withCheckedThrowingContinuation { continuation in
            queue.async {
                do {
                    let words = try JSONSerialization.jsonObject(with: JSONEncoder().encode(dictionary))
                    var request = try JSONSerialization.data(withJSONObject: ["text": text, "speaker": speaker, "speed": speed, "dictionary": words])
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
    func analyze(words: [String], dictionary: [ReadingEntry] = []) async throws -> [WordCheck] {
        try await withCheckedThrowingContinuation { continuation in
            queue.async {
                do {
                    let entries = try JSONSerialization.jsonObject(with: JSONEncoder().encode(dictionary))
                    var request = try JSONSerialization.data(withJSONObject: ["op": "analyze", "words": words, "dictionary": entries])
                    request.append(10); try self.input?.write(contentsOf: request)
                    let data = try self.line()
                    struct Reply: Decodable { let words: [WordCheck] }
                    continuation.resume(returning: try JSONDecoder().decode(Reply.self, from: data).words)
                } catch { continuation.resume(throwing: error) }
            }
        }
    }
    deinit { close() }
}

struct Page: Codable, Sendable {
    let url: String
    let text: String
    var documentID: String? = nil
    var selectionID: String? = nil
}
struct PagePosition: Codable, Sendable {
    let url: String
    var documentID: String? = nil
    var selectionID: String? = nil
    func matches(_ page: Page) -> Bool {
        url == page.url && documentID == page.documentID && selectionID == page.selectionID
    }
}
protocol SafariSource: Sendable {
    func currentURL() async throws -> String
    func page() async throws -> Page
    func position() async throws -> PagePosition
}
extension SafariSource {
    func position() async throws -> PagePosition { PagePosition(url: try await currentURL()) }
}
struct SafariSourceLive: SafariSource {
    private func execute(_ source: String) async throws -> String {
        try await Task.detached {
            var error: NSDictionary?
            guard let script = NSAppleScript(source: "with timeout of 12 seconds\n" + source + "\nend timeout") else { throw ReaderError(message: "Safariの取得処理を作成できませんでした。") }
            let reply = script.executeAndReturnError(&error)
            if let error {
                let number = error[NSAppleScript.errorNumber] as? Int ?? 0
                if number == -1743 { throw ReaderError(message: "システム設定 → プライバシーとセキュリティ → オートメーションで、RSpeechによるSafariの操作を許可してください。") }
                if number == -1712 { throw ReaderError(message: "Safariの応答がありません。Safariでページを表示して、もう一度 ▶ を押してください。") }
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
    private func javascript(_ source: String) async throws -> String {
        let escaped = source.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"")
        return try await execute("tell application \"Safari\" to do JavaScript \"\(escaped)\" in current tab of front window")
    }
    private func selectionScript() throws -> String {
        try String(contentsOf: Bundle.main.url(forResource: "PageSelection", withExtension: "js")!, encoding: .utf8)
    }
    func position() async throws -> PagePosition {
        let json = try await javascript(selectionScript())
        guard let data = json.data(using: .utf8), let position = try? JSONDecoder().decode(PagePosition.self, from: data) else {
            throw ReaderError(message: "Safariの選択位置を取得できませんでした。")
        }
        return position
    }
    private func extract(respectSelection: Bool) async throws -> Page {
        let extractor = try String(contentsOf: Bundle.main.url(forResource: "PageExtraction", withExtension: "js")!, encoding: .utf8)
        let source = try selectionScript() + ";\n" + extractor + "(" + (respectSelection ? "true" : "false") + ")"
        let json = try await javascript(source)
        guard let data = json.data(using: .utf8), let page = try? JSONDecoder().decode(Page.self, from: data) else {
            throw ReaderError(message: "ページの本文を取得できませんでした。")
        }
        return page
    }
    func page() async throws -> Page { try await extract(respectSelection: true) }

}
protocol SpeechEngine: AnyObject, Sendable {
    func start() async throws -> [Voice]
    func synthesize(_ text: String, speaker: Int, speed: Double, dictionary: [ReadingEntry]) async throws -> Data
    func close()
    func analyze(words: [String], dictionary: [ReadingEntry]) async throws -> [WordCheck]
}
extension SpeechEngine {
    func synthesize(_ text: String, speaker: Int, speed: Double) async throws -> Data {
        try await synthesize(text, speaker: speaker, speed: speed, dictionary: [])
    }
}
extension Engine: SpeechEngine {}

@MainActor final class Reader: ObservableObject {
    @Published private(set) var text = ""
    @Published private(set) var pageURL: String?
    private var documentID: String?
    private var selectionID: String?
    @Published var status = "Safariの本文を選択して ▶ を押すと、その位置から読みます。"
    @Published var voices: [Voice] = []
    @Published var expanded = false
    @Published var speaker: Int { didSet { preferences.set(speaker, forKey: "speaker"); settingsChanged() } }
    @Published var speed: Double { didSet { preferences.set(speed, forKey: "speed"); settingsChanged() } }
    let dictionary: ReadingDictionary
    private let preferences: UserDefaults
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
    private var prefetchTask: Task<Data, Error>?
    private var prefetchIndex: Int?
    private var prefetchRevision = 0
    private var settingsRevision = 0
    private var nextIndex: Int?
    private var playbackParts: [String] = []
    private var engineReady = false
    private var wordCheckTask: Task<Void, Never>?
    private var wordCheckEngine: (any SpeechEngine)?
    private var previewTask: Task<Void, Never>?
    private var previewPlayer: AVAudioPlayer?
    private var previewEngine: (any SpeechEngine)?
    private var ownsPreviewEngine = false
    private var previewGeneration = UUID()
    var isPreviewAudioPlaying: Bool { previewPlayer?.isPlaying ?? false }
    var isAudioPlaying: Bool { player?.isPlaying ?? false }

    init(safari: any SafariSource = SafariSourceLive(), muted: Bool = false, dictionary: ReadingDictionary? = nil, preferences: UserDefaults = .standard, makeEngine: @escaping () -> any SpeechEngine = { Engine() }) {
        self.safari = safari; self.muted = muted; self.makeEngine = makeEngine
        self.preferences = preferences
        self.speaker = preferences.object(forKey: "speaker") as? Int ?? 2
        self.speed = preferences.object(forKey: "speed") as? Double ?? 1.2
        self.dictionary = dictionary ?? ReadingDictionary(defaults: preferences)
        self.dictionary.onChange = { [weak self] in self?.settingsChanged() }
    }
    private func canReusePage(at position: PagePosition) -> Bool {
        let newDocument = position.documentID != nil && position.documentID != documentID
        let newSelection = position.selectionID != nil && position.selectionID != selectionID
        let clearedOnRestart = !busy && selectionID != nil && position.selectionID == nil
        return position.url == pageURL && !newDocument && !newSelection && !clearedOnRestart && !text.isEmpty
    }
    // Both playback and word collection use this exact extraction and navigation check.
    private func fetchPage() async throws -> Page {
        let page = try await safari.page()
        guard try await safari.position().matches(page) else {
            throw ReaderError(message: "取得中にページまたは選択位置が変わりました。もう一度実行してください。")
        }
        guard !page.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw ReaderError(message: "読み上げられる本文がありません。")
        }
        return page
    }
    func checkPageWords() {
        guard !dictionary.checking else { return }
        dictionary.checks = []
        dictionary.checking = true; dictionary.scanMessage = "Safariの本文と英単語の読みを確認中…"
        wordCheckTask = Task {
            let analyzer = makeEngine(); wordCheckEngine = analyzer
            defer { analyzer.close(); wordCheckEngine = nil; dictionary.checking = false }
            do {
                let position = try await safari.position()
                let page: Page
                if canReusePage(at: position) {
                    page = Page(url: pageURL!, text: text, documentID: documentID, selectionID: selectionID)
                } else { page = try await fetchPage() }
                try Task.checkCancellation()
                let words = englishWords(page.text)
                guard !words.isEmpty else { dictionary.checks = []; dictionary.scanMessage = "英単語は見つかりませんでした。"; return }
                _ = try await analyzer.start()
                try Task.checkCancellation()
                let results = try await analyzer.analyze(words: Array(words.prefix(200)), dictionary: [])
                try Task.checkCancellation()
                dictionary.checks = results.sorted { $0.isSpelling && !$1.isSpelling }
                dictionary.scanMessage = "\(results.count)語を確認しました。未登録のアルファベット読み候補：\(dictionary.pendingChecks.count)語。" + (words.count > 200 ? "先頭200語を解析しています。" : "")
            } catch {
                if !Task.isCancelled { dictionary.scanMessage = error.localizedDescription }
            }
        }
    }
    func cancelWordCheck() { wordCheckTask?.cancel(); wordCheckEngine?.close() }
    func stopPronunciationPreview() {
        previewGeneration = UUID(); previewTask?.cancel(); previewTask = nil
        previewPlayer?.stop(); previewPlayer = nil
        if ownsPreviewEngine { previewEngine?.close() }
        previewEngine = nil; ownsPreviewEngine = false; dictionary.previewing = false
    }
    func previewPronunciation() {
        if dictionary.previewing { stopPronunciationPreview(); dictionary.previewStatus = "試聴を停止しました。"; return }
        let draft: ReadingEntry
        do { draft = try dictionary.draftEntry() }
        catch { dictionary.previewStatus = error.localizedDescription; return }
        // An audition replaces an in-flight fetch so it cannot start page audio behind the preview.
        fetchGeneration = UUID(); fetching = false
        if busy && !paused { paused = true; player?.pause(); status = "一時停止中" }
        let id = UUID(); previewGeneration = id
        let voice = speaker, rate = speed
        let borrowed = engineReady ? engine : nil
        let audition = borrowed ?? makeEngine()
        previewEngine = audition; ownsPreviewEngine = borrowed == nil
        dictionary.previewing = true; dictionary.previewStatus = "試聴の音声を準備中…"
        previewTask = Task {
            defer {
                if previewGeneration == id {
                    if ownsPreviewEngine { audition.close() }
                    previewEngine = nil; ownsPreviewEngine = false; previewPlayer = nil
                    dictionary.previewing = false; previewTask = nil
                }
            }
            do {
                if borrowed == nil { _ = try await audition.start() }
                try Task.checkCancellation()
                let data = try await audition.synthesize(draft.word, speaker: voice, speed: rate, dictionary: [draft])
                guard previewGeneration == id else { return }
                try Task.checkCancellation()
                let audio = try AVAudioPlayer(data: data)
                previewPlayer = audio
                if muted { audio.volume = 0 }
                audio.prepareToPlay()
                guard audio.play() else { throw ReaderError(message: "試聴を再生できませんでした。") }
                dictionary.previewStatus = "試聴中（アクセント\(draft.accent)）"
                while audio.isPlaying { try await Task.sleep(nanoseconds: 10_000_000) }
                dictionary.previewStatus = "試聴が終わりました。追加・更新すると保存されます。"
            } catch {
                if previewGeneration == id && !Task.isCancelled { dictionary.previewStatus = error.localizedDescription }
            }
        }
    }
    func toggle() {
        stopPronunciationPreview()
        guard !fetching else { return }
        if busy && !paused {
            paused = true; player?.pause(); status = "一時停止中"; return
        }
        fetching = true; let request = UUID(); fetchGeneration = request
        Task {
            defer { if fetchGeneration == request { fetching = false } }
            do {
                let position = try await safari.position()
                guard fetchGeneration == request else { return }
                if !canReusePage(at: position) {
                    // Clear the old page before fetching; a failed fetch must not resume old speech.
                    stopPlayback(); text = ""; pageURL = nil; documentID = nil; selectionID = nil
                    status = "Safariから本文を取得中…"
                    let page = try await fetchPage()
                    guard fetchGeneration == request else { return }
                    text = page.text; pageURL = page.url; documentID = page.documentID; selectionID = page.selectionID
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
        playbackParts = parts; nextIndex = 0
        task = Task {
            do {
                if engine == nil {
                    status = "VOICEVOXを準備中…"
                    let e = makeEngine(); engine = e
                    let loaded = try await e.start()
                    guard generation == id else { return }
                    engineReady = true; voices = loaded
                    if !voices.contains(where: { $0.id == speaker }) { speaker = 2 }
                }
                guard engine != nil else { return }
                for index in parts.indices {
                    guard generation == id, !Task.isCancelled else { return }
                    status = paused ? "一時停止中" : "音声を準備中 \(index + 1) / \(parts.count)"
                    nextIndex = index
                    var prepared: AVAudioPlayer?
                    while generation == id && !Task.isCancelled {
                        let data = try await preparedAudio(index: index, generation: id)
                        guard generation == id, !Task.isCancelled else { return }
                        let revision = settingsRevision
                        let audio = try AVAudioPlayer(data: data); player = audio; audioStarted = false
                        if muted { audio.volume = 0 }
                        audio.prepareToPlay()
                        while paused { try await Task.sleep(nanoseconds: 10_000_000) }
                        guard generation == id, !Task.isCancelled else { return }
                        if revision != settingsRevision { continue }
                        prepared = audio; break
                    }
                    guard let audio = prepared else { throw CancellationError() }
                    guard audio.play() else { throw ReaderError(message: "音声を再生できませんでした。Macの出力先を確認してください。") }
                    audioStarted = true
                    nextIndex = index + 1 < parts.count ? index + 1 : nil
                    if let nextIndex { prefetch(index: nextIndex) }
                    status = "読み上げ中 \(index + 1) / \(parts.count)"
                    while audio.isPlaying || paused { try await Task.sleep(nanoseconds: 10_000_000) }
                    player = nil; audioStarted = false
                }
                busy = false; paused = false; nextIndex = nil; playbackParts = []; status = "読み上げが終わりました。"
            } catch {
                guard generation == id else { return }
                stopPlayback(); status = error.localizedDescription
            }
        }
    }
    private func settingsChanged() {
        settingsRevision += 1
        prefetchTask?.cancel(); prefetchTask = nil; prefetchIndex = nil
        if busy, engineReady, let nextIndex { prefetch(index: nextIndex) }
    }
    private func prefetch(index: Int) {
        guard playbackParts.indices.contains(index), let engine, engineReady else { return }
        if prefetchIndex == index && prefetchRevision == settingsRevision && prefetchTask != nil { return }
        prefetchTask?.cancel()
        let spoken = playbackParts[index]
        let entries = dictionary.effectiveEntries
        let speaker = self.speaker, speed = self.speed
        prefetchIndex = index; prefetchRevision = settingsRevision
        prefetchTask = Task {
            try Task.checkCancellation()
            let data = try await engine.synthesize(spoken, speaker: speaker, speed: speed, dictionary: entries)
            try Task.checkCancellation()
            return data
        }
    }
    private func preparedAudio(index: Int, generation id: UUID) async throws -> Data {
        while generation == id && !Task.isCancelled {
            prefetch(index: index)
            guard let pending = prefetchTask else { throw CancellationError() }
            let revision = prefetchRevision
            do {
                let data = try await pending.value
                guard generation == id else { throw CancellationError() }
                if revision != settingsRevision { continue }
                prefetchTask = nil; prefetchIndex = nil
                return data
            } catch {
                guard generation == id else { throw CancellationError() }
                if revision != settingsRevision { continue }
                throw error
            }
        }
        throw CancellationError()
    }
    private func stopPlayback() {
        generation = UUID(); task?.cancel(); task = nil
        player?.stop(); player = nil; audioStarted = false
        prefetchTask?.cancel(); prefetchTask = nil; prefetchIndex = nil
        nextIndex = nil; playbackParts = []; engineReady = false
        engine?.close(); engine = nil; busy = false; paused = false
    }
    func stop() {
        stopPronunciationPreview()
        fetchGeneration = UUID(); fetching = false
        stopPlayback(); status = "停止しました。"
    }
}

struct ContentView: View {
    @ObservedObject var reader: Reader
    var openSettings: () -> Void = {}
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
                }.frame(width: 190)
                Picker("速度", selection: $reader.speed) {
                    ForEach([0.75, 1.0, 1.2, 1.5, 1.75, 2.0], id: \.self) { Text(String(format: "%.2g倍", $0)).tag($0) }
                }.frame(width: 135)
            }
            Text(reader.status).font(.callout).foregroundStyle(.secondary).textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
            DisclosureGroup("取得した本文（\(reader.text.count)文字）", isExpanded: $reader.expanded) {
                ScrollView { Text(reader.text.isEmpty ? "本文はまだ取得していません。" : reader.text).frame(maxWidth: .infinity, alignment: .leading).textSelection(.enabled).padding(8) }
                    .frame(height: 250).background(Color(nsColor: .textBackgroundColor)).cornerRadius(5)
            }
            HStack {
            Text("VOICEVOX:\(reader.voices.first(where: { $0.id == reader.speaker })?.name ?? [2:"四国めたん", 3:"ずんだもん", 8:"春日部つむぎ", 10:"雨晴はう", 14:"冥鳴ひまり", 52:"雀松朱司"][reader.speaker] ?? "四国めたん")").font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button(action: openSettings) { Image(systemName: "gearshape") }.buttonStyle(.plain).accessibilityLabel("設定")
            }
        }.padding(18).frame(width: 530)
    }
}

@MainActor final class AppDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate {
    let dictionary = ReadingDictionary(shared: true)
    lazy var reader = Reader(dictionary: dictionary)
    var settingsWindow: NSWindow?
    var window: NSWindow!
    var item: NSStatusItem!
    func applicationDidFinishLaunching(_ notification: Notification) {
        let mainMenu = NSMenu()
        let appMenuItem = NSMenuItem(); let appMenu = NSMenu()
        appMenu.addItem(withTitle: "設定…", action: #selector(settings), keyEquivalent: ",").target = self
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: "RSpeechを終了", action: #selector(quit), keyEquivalent: "q").target = self
        appMenuItem.submenu = appMenu; mainMenu.addItem(appMenuItem)
        let editItem = NSMenuItem(); let editMenu = NSMenu(title: "編集")
        editMenu.addItem(withTitle: "取り消す", action: Selector(("undo:")), keyEquivalent: "z")
        editMenu.addItem(.separator())
        editMenu.addItem(withTitle: "カット", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        editMenu.addItem(withTitle: "コピー", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        editMenu.addItem(withTitle: "ペースト", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        editMenu.addItem(withTitle: "すべてを選択", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        editItem.submenu = editMenu; mainMenu.addItem(editItem)
        let windowItem = NSMenuItem(); let windowMenu = NSMenu(title: "ウインドウ")
        windowMenu.addItem(withTitle: "読み上げウインドウを開く", action: #selector(show), keyEquivalent: "1").target = self
        windowMenu.addItem(withTitle: "ウインドウを閉じる", action: #selector(NSWindow.performClose(_:)), keyEquivalent: "w")
        windowItem.submenu = windowMenu; mainMenu.addItem(windowItem); NSApp.mainMenu = mainMenu
        window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 566, height: 190), styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false)
        window.title = "RSpeech"; window.isReleasedWhenClosed = false
        window.contentView = NSHostingView(rootView: ContentView(reader: reader, openSettings: { [weak self] in self?.settings() })); window.center(); show()
        item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        item.button?.image = NSImage(systemSymbolName: "speaker.wave.2", accessibilityDescription: "RSpeech")
        let menu = NSMenu()
        menu.addItem(withTitle: "ウインドウを開く", action: #selector(show), keyEquivalent: "").target = self
        menu.addItem(withTitle: "再生 / 一時停止", action: #selector(fetch), keyEquivalent: "").target = self
        menu.addItem(withTitle: "設定…", action: #selector(settings), keyEquivalent: "").target = self
        menu.addItem(withTitle: "読み上げを停止", action: #selector(stop), keyEquivalent: "").target = self
        menu.addItem(.separator())
        menu.addItem(withTitle: "終了", action: #selector(quit), keyEquivalent: "q").target = self
        item.menu = menu
        if dictionary.autoUpdate { dictionary.updateCommon() }
    }
    @objc func settings() {
        if settingsWindow == nil {
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 720, height: 530), styleMask: [.titled, .closable], backing: .buffered, defer: false)
            window.title = "RSpeech 設定"; window.isReleasedWhenClosed = false
            window.contentView = NSHostingView(rootView: DictionarySettingsView(dictionary: dictionary, checkPage: { [weak self] in self?.reader.checkPageWords() }, preview: { [weak self] in self?.reader.previewPronunciation() })); window.center()
            window.delegate = self
            settingsWindow = window
        }
        NSApp.activate(ignoringOtherApps: true); settingsWindow?.makeKeyAndOrderFront(nil)
    }
    func windowWillClose(_ notification: Notification) {
        if let closing = notification.object as? NSWindow, closing === settingsWindow { reader.stopPronunciationPreview() }
    }
    @objc func show() { NSApp.activate(ignoringOtherApps: true); window.makeKeyAndOrderFront(nil) }
    @objc func fetch() { show(); reader.toggle() }
    @objc func stop() { reader.stop() }
    @objc func quit() { NSApp.terminate(nil) }
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool { show(); return true }
    func applicationWillTerminate(_ notification: Notification) { reader.stop(); reader.cancelWordCheck() }
}

@main
struct RSpeechApp {
    static func main() {
if CommandLine.arguments.contains("--self-test") {
    let text = "日本語とSafari、APIを同じ声で読みます。\n" + String(repeating: "長文です。", count: 200)
    let parts = chunks(text)
    precondition(parts.joined() == text)
    precondition(parts.allSatisfy { $0.count <= 180 })
    precondition(chunks(" \n\t").isEmpty)
    let airHome = URL(fileURLWithPath: "/test/home/AirUser")
    precondition(voicevoxModelRoot(home: airHome).path == "/test/home/AirUser/Library/Application Support/RTranslate/Assets/voicevox")
    do {
        try validateVoicevoxModels(at: URL(fileURLWithPath: "/nonexistent-rspeech-test-voicevox"))
        preconditionFailure("Missing shared data must fail, never use app data")
    } catch { precondition(error.localizedDescription.contains("RTranslate")) }
    print("Text chunk and shared-model path/error checks passed")
} else if CommandLine.arguments.contains("--audio-self-test") {
    MainActor.assumeIsolated {
        Task { @MainActor in
            let engine = Engine()
            do {
                let voices = try await engine.start()
                precondition(voices.count == 6)
                let words = try await engine.analyze(words: ["ARTEX", "Linux", "API"])
                precondition(words.first(where: { $0.word == "ARTEX" })?.isSpelling == true)
                precondition(words.first(where: { $0.word == "Linux" })?.isSpelling == false)
                for speaker in [2, 14, 52, 2] {
                    let spoken = pronunciation("ARTEXとSafariのページを同じ声で読みます。", entries: [ReadingEntry(word: "ARTEX", reading: "アルテックス")])
                    precondition(spoken.hasPrefix("アルテックス"))
                    let wav = try await engine.synthesize(spoken, speaker: speaker, speed: 1.5)
                    let audio = try AVAudioPlayer(data: wav)
                    precondition(audio.duration > 0)
                    if speaker == 2 {
                        audio.volume = 0
                        precondition(audio.play())
                        while audio.isPlaying { try await Task.sleep(nanoseconds: 100_000_000) }
                    }
                }
                engine.close()
                print("6 voices, actual word analysis, dictionary reading synthesis, model switching, muted playback passed")
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

    }
}

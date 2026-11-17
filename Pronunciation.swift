import Foundation
import SwiftUI
import UniformTypeIdentifiers

struct ReadingEntry: Codable, Identifiable, Equatable, Sendable {
    var id: UUID = UUID()
    var word: String
    var reading: String
    var accent: Int = 0
    var priority: Int = 5
    init(id: UUID = UUID(), word: String, reading: String, accent: Int = 0, priority: Int = 5) {
        self.id = id; self.word = word; self.reading = reading; self.accent = accent; self.priority = priority
    }
    enum CodingKeys: String, CodingKey { case id, word, reading, accent, priority }
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        word = try c.decode(String.self, forKey: .word); reading = try c.decode(String.self, forKey: .reading)
        accent = try c.decodeIfPresent(Int.self, forKey: .accent) ?? 0
        priority = try c.decodeIfPresent(Int.self, forKey: .priority) ?? 5
    }
}
struct CommonDictionaryFile: Codable, Sendable {
    let schemaVersion: Int
    let version: String
    let entries: [ReadingEntry]
}
func kanaReading(_ text: String) -> String {
    text.trimmingCharacters(in: .whitespacesAndNewlines).applyingTransform(.hiraganaToKatakana, reverse: false) ?? text
}
func readingMoras(_ text: String) -> Int {
    text.filter { !"ァィゥェォャュョヮ".contains($0) }.count
}
func validateReadings(_ entries: [ReadingEntry], limit: Int = 2000) throws {
    guard entries.count <= limit else { throw ReaderError(message: "辞書の登録件数が上限を超えています。") }
    var seen = Set<String>()
    for entry in entries {
        let reading = kanaReading(entry.reading)
        guard !entry.word.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, entry.word.count <= 64,
              entry.word.rangeOfCharacter(from: .newlines) == nil, entry.word == entry.word.trimmingCharacters(in: .whitespacesAndNewlines),
              (1...64).contains(reading.count), reading.range(of: "^[ァ-ヴー]+$", options: .regularExpression) != nil,
              readingMoras(reading) > 0, !"ァィゥェォャュョヮー".contains(reading.first!), reading.range(of: "[ァィゥェォャュョヮ]{2}", options: .regularExpression) == nil,
              (0...readingMoras(reading)).contains(entry.accent), (0...10).contains(entry.priority),
              seen.insert(entry.word.lowercased()).inserted else {
            throw ReaderError(message: "辞書の文字・かな読み・アクセント・優先度を確認してください：\(entry.word)")
        }
    }
}
func decodeCommonDictionary(_ data: Data) throws -> CommonDictionaryFile {
    guard data.count <= 1_048_576 else { throw ReaderError(message: "共通辞書が大きすぎます。") }
    let file = try JSONDecoder().decode(CommonDictionaryFile.self, from: data)
    guard file.schemaVersion == 1, !file.version.isEmpty, file.version.count <= 64 else { throw ReaderError(message: "未対応の辞書形式です。") }
    let entries = file.entries.map { entry -> ReadingEntry in
        var normalized = entry; normalized.reading = kanaReading(entry.reading); return normalized
    }
    try validateReadings(entries)
    return CommonDictionaryFile(schemaVersion: file.schemaVersion, version: file.version, entries: entries)
}
func decodeImportedReadings(_ data: Data) throws -> [ReadingEntry] {
    guard data.count <= 1_048_576 else { throw ReaderError(message: "辞書JSONが大きすぎます。") }
    if let entries = try? JSONDecoder().decode([ReadingEntry].self, from: data) { try validateReadings(entries, limit: 1000); return entries }
    if let file = try? decodeCommonDictionary(data) { return file.entries }
    struct EngineWord: Decodable { let surface: String; let pronunciation: String; let accent_type: Int; let priority: Int }
    let words = try JSONDecoder().decode([String: EngineWord].self, from: data)
    let entries = words.values.map { value -> ReadingEntry in
        let word = String(String.UnicodeScalarView(value.surface.unicodeScalars.map { scalar in
            (0xFF01...0xFF5E).contains(scalar.value) ? UnicodeScalar(scalar.value - 0xFEE0)! : scalar
        }))
        return ReadingEntry(word: word, reading: value.pronunciation, accent: value.accent_type, priority: value.priority)
    }
    try validateReadings(entries, limit: 1000)
    return entries
}

func pronunciation(_ text: String, entries: [ReadingEntry]) -> String {
    let ordered = entries.sorted { $0.word.count > $1.word.count }
    guard !ordered.isEmpty else { return text }
    let ascii = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789_")
    let patterns = ordered.map { entry -> String in
        let first = entry.word.unicodeScalars.first.map { ascii.contains($0) } ?? false
        let last = entry.word.unicodeScalars.last.map { ascii.contains($0) } ?? false
        return (first ? "(?<![A-Za-z0-9_])" : "") + NSRegularExpression.escapedPattern(for: entry.word) + (last ? "(?![A-Za-z0-9_])" : "")
    }
    guard let regex = try? NSRegularExpression(pattern: patterns.joined(separator: "|"), options: .caseInsensitive) else { return text }
    let original = text as NSString
    let result = NSMutableString(string: text)
    for match in regex.matches(in: text, range: NSRange(location: 0, length: original.length)).reversed() {
        let word = original.substring(with: match.range)
        if let entry = ordered.first(where: { $0.word.compare(word, options: [.literal, .caseInsensitive]) == .orderedSame }) {
            result.replaceCharacters(in: match.range, with: entry.reading)
        }
    }
    return result as String
}

struct WordPart: Decodable, Sendable { let word: String; let reading: String }
struct WordCheck: Decodable, Identifiable, Sendable {
    var id: String { word }
    let word: String
    let reading: String
    let isSpelling: Bool
    var unresolvedParts: [WordPart]? = nil
    var desiredReading = ""
    enum CodingKeys: String, CodingKey { case word, reading, isSpelling, unresolvedParts }
}
func expandWordChecks(_ checks: [WordCheck]) -> [WordCheck] {
    var seen = Set<String>()
    return checks.flatMap { check -> [WordCheck] in
        if let parts = check.unresolvedParts, !parts.isEmpty {
            return parts.map { WordCheck(word: $0.word, reading: $0.reading, isSpelling: true) }
        }
        return [check]
    }.filter { seen.insert($0.word.lowercased()).inserted }
}
func englishWords(_ text: String) -> [String] {
    let regex = try! NSRegularExpression(pattern: "(?<![A-Za-z0-9_])[A-Za-z][A-Za-z0-9]*(?:[-_'][A-Za-z0-9]+)*(?![A-Za-z0-9_])")
    let value = text as NSString
    var seen = Set<String>()
    return regex.matches(in: text, range: NSRange(location: 0, length: value.length)).compactMap {
        let word = value.substring(with: $0.range)
        guard (2...64).contains(word.count), seen.insert(word.lowercased()).inserted else { return nil }
        return word
    }
}

@MainActor final class ReadingDictionary: ObservableObject {
    @Published private(set) var entries: [ReadingEntry] = []
    @Published var word = ""
    @Published var reading = ""
    @Published var editingID: UUID?
    @Published var accent = 0
    @Published var priority = 5
    @Published private(set) var commonEntries: [ReadingEntry] = []
    @Published private(set) var commonVersion = ""
    @Published var commonStatus = "共通辞書を準備中…"
    @Published var previewing = false
    @Published var previewStatus = ""
    @Published var updating = false
    @Published var commonSearch = ""
    @Published var autoUpdate: Bool { didSet { defaults.set(autoUpdate, forKey: "commonDictionaryAutoUpdate") } }
    private var cacheURL: URL?
    static let commonURL = URL(string: "https://raw.githubusercontent.com/haruxbt/RSpeech/main/Dictionary/common-ja.json")!
    var effectiveEntries: [ReadingEntry] {
        var values = Dictionary(commonEntries.map { ($0.word.lowercased(), $0) }, uniquingKeysWith: { _, new in new })
        for entry in entries { values[entry.word.lowercased()] = entry }
        return values.values.sorted { $0.word < $1.word }
    }
    @Published var message = ""
    @Published var tab = 0
    @Published var checks: [WordCheck] = []
    @Published var checking = false
    @Published var scanMessage = "現在のSafariページの英単語を調べられます。"
    var pendingChecks: [WordCheck] {
        let registered = Set(effectiveEntries.map { $0.word.lowercased() })
        return checks.filter { $0.isSpelling && !registered.contains($0.word.lowercased()) }
    }
    private let defaults: UserDefaults
    private let key = "readingDictionaryV1"
    private var writable = true
    var onChange: (() -> Void)?
    init(defaults: UserDefaults = .standard, shared: Bool = false, cacheURL: URL? = nil) {
        self.defaults = defaults
        self.autoUpdate = defaults.object(forKey: "commonDictionaryAutoUpdate") as? Bool ?? true
        self.cacheURL = cacheURL ?? (shared ? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support/RSpeech/common-dictionary.json") : nil)
        if shared, let url = Bundle.main.url(forResource: "common-ja", withExtension: "json"), let data = try? Data(contentsOf: url), let file = try? decodeCommonDictionary(data) {
            commonEntries = file.entries; commonVersion = file.version; commonStatus = "共通辞書 \(file.version)・\(file.entries.count)語"
        }
        if let url = self.cacheURL, let data = try? Data(contentsOf: url), let file = try? decodeCommonDictionary(data), file.version.compare(commonVersion, options: .numeric) != .orderedAscending {
            commonEntries = file.entries; commonVersion = file.version; commonStatus = "保存済み共通辞書 \(file.version)・\(file.entries.count)語"
        }
        if let data = defaults.data(forKey: key) {
            do { entries = try JSONDecoder().decode([ReadingEntry].self, from: data) }
            catch { writable = false; message = "保存済みの辞書を読み込めません。元データを保護するため変更を保存しません。" }
        }
        if writable { _ = try? pruneCommonMatches() }
    }
    func draftEntry() throws -> ReadingEntry {
        let entry = ReadingEntry(word: word.trimmingCharacters(in: .whitespacesAndNewlines), reading: kanaReading(reading), accent: accent, priority: priority)
        try validateReadings([entry])
        return entry
    }
    // UUIDs identify local rows; pronunciation equality ignores row identity and English case.
    private func pruneCommonMatches() throws -> Int {
        let common = Dictionary(commonEntries.map { ($0.word.lowercased(), $0) }, uniquingKeysWith: { _, new in new })
        let kept = entries.filter { entry in
            guard let standard = common[entry.word.lowercased()] else { return true }
            return kanaReading(entry.reading) != kanaReading(standard.reading) || entry.accent != standard.accent || entry.priority != standard.priority
        }
        let removed = entries.count - kept.count
        if removed > 0 {
            try save(kept)
            if let id = editingID, !kept.contains(where: { $0.id == id }) { reset() }
        }
        return removed
    }
    private func save(_ updated: [ReadingEntry]) throws {
        guard writable else { throw ReaderError(message: "辞書を読み込めないため保存できません。") }
        let data = try JSONEncoder().encode(updated)
        defaults.set(data, forKey: key)
        entries = updated
        onChange?()
    }
    func register() {
        do {
            let term = word.trimmingCharacters(in: .whitespacesAndNewlines)
            let kana = kanaReading(reading)
            guard !term.isEmpty, !kana.isEmpty, term.count <= 64, kana.count <= 64,
                  term.rangeOfCharacter(from: .newlines) == nil, kana.rangeOfCharacter(from: .newlines) == nil else {
                throw ReaderError(message: "文字と読みをそれぞれ1〜64文字で入力してください。改行は使えません。")
            }
            try validateReadings([ReadingEntry(word: term, reading: kana, accent: accent, priority: priority)])
            var updated = entries
            let existing = editingID.flatMap { id in updated.firstIndex(where: { $0.id == id }) }
                ?? updated.firstIndex(where: { $0.word.compare(term, options: .caseInsensitive) == .orderedSame })
            if let index = existing {
                let id = updated[index].id
                guard !updated.contains(where: { $0.id != id && $0.word.compare(term, options: .caseInsensitive) == .orderedSame }) else {
                    throw ReaderError(message: "同じ文字がすでに登録されています。")
                }
                updated[index] = ReadingEntry(id: id, word: term, reading: kana, accent: accent, priority: priority)
            } else {
                guard updated.count < 1000 else { throw ReaderError(message: "個人辞書は1000件まで登録できます。") }
                updated.append(ReadingEntry(word: term, reading: kana, accent: accent, priority: priority))
            }
            try save(updated)
            reset(); message = "登録しました。変更は次の文から反映されます。"
        } catch { message = error.localizedDescription }
    }
    func applyCommon(_ data: Data, persist: Bool = true) throws {
        let file = try decodeCommonDictionary(data)
        guard file.version.compare(commonVersion, options: .numeric) != .orderedAscending else { throw ReaderError(message: "古い共通辞書のため更新しませんでした。") }
        if persist, let cacheURL {
            try FileManager.default.createDirectory(at: cacheURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            try data.write(to: cacheURL, options: .atomic)
        }
        let before = effectiveEntries
        commonEntries = file.entries; commonVersion = file.version
        let removed = try pruneCommonMatches()
        commonStatus = "共通辞書 \(file.version)・\(file.entries.count)語（個人登録が優先）" + (removed > 0 ? "・一致した個人登録\(removed)件を整理しました" : "")
        if before != effectiveEntries { onChange?() }
    }
    func updateCommon() {
        guard !updating else { return }
        updating = true
        Task {
            defer { updating = false }
            do {
                let config = URLSessionConfiguration.ephemeral
                config.httpCookieStorage = nil; config.urlCredentialStorage = nil
                config.httpShouldSetCookies = false; config.timeoutIntervalForRequest = 15
                let session = URLSession(configuration: config)
                defer { session.invalidateAndCancel() }
                var request = URLRequest(url: Self.commonURL)
                request.setValue("application/json", forHTTPHeaderField: "Accept")
                request.cachePolicy = .reloadIgnoringLocalCacheData
                let (data, response) = try await session.data(for: request)
                guard (response as? HTTPURLResponse)?.statusCode == 200, response.url == Self.commonURL else { throw ReaderError(message: "GitHubの辞書を取得できませんでした。") }
                try applyCommon(data)
            } catch { commonStatus = "更新できませんでした。手元の共通辞書を使います。" }
        }
    }
    func importJSON(_ data: Data) throws {
        let imported = try decodeImportedReadings(data)
        var updated = entries
        for entry in imported {
            if let index = updated.firstIndex(where: { $0.word.compare(entry.word, options: .caseInsensitive) == .orderedSame }) {
                updated[index] = ReadingEntry(id: updated[index].id, word: entry.word, reading: kanaReading(entry.reading), accent: entry.accent, priority: entry.priority)
            } else { updated.append(ReadingEntry(word: entry.word, reading: kanaReading(entry.reading), accent: entry.accent, priority: entry.priority)) }
        }
        guard updated.count <= 1000 else { throw ReaderError(message: "個人辞書は1000件まで登録できます。") }
        try save(updated)
        commonStatus = "JSONから\(imported.count)件を個人辞書に登録しました。"
    }
    func chooseImport() {
        let panel = NSOpenPanel(); panel.allowedContentTypes = [.json]; panel.allowsMultipleSelection = false
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do { try importJSON(Data(contentsOf: url)) } catch { commonStatus = error.localizedDescription }
    }
    func exportJSON() throws -> Data { try JSONEncoder().encode(entries) }
    func chooseExport() {
        let panel = NSSavePanel(); panel.nameFieldStringValue = "RSpeech-user-dictionary.json"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do { try exportJSON().write(to: url, options: .atomic); commonStatus = "個人辞書をJSONで書き出しました。" }
        catch { commonStatus = error.localizedDescription }
    }
    func registerChecked() {
        do {
            let additions = checks.filter { !$0.desiredReading.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
            guard !additions.isEmpty else { scanMessage = "登録する読みを入力してください。"; return }
            var updated = entries
            for addition in additions {
                let reading = kanaReading(addition.desiredReading)
                try validateReadings([ReadingEntry(word: addition.word, reading: reading)])
                guard reading.count <= 64, reading.rangeOfCharacter(from: .newlines) == nil else {
                    throw ReaderError(message: "読みは1〜64文字、改行なしで入力してください。")
                }
                if let index = updated.firstIndex(where: { $0.word.compare(addition.word, options: .caseInsensitive) == .orderedSame }) {
                    updated[index].reading = reading
                } else {
                    updated.append(ReadingEntry(word: addition.word, reading: reading))
                }
            }
            guard updated.count <= 1000 else { throw ReaderError(message: "個人辞書は1000件まで登録できます。") }
            try save(updated)
            for index in checks.indices { checks[index].desiredReading = "" }
            scanMessage = "\(additions.count)件を登録しました。変更は次の文から反映されます。"
        } catch { scanMessage = error.localizedDescription }
    }
    func edit(_ entry: ReadingEntry) { word = entry.word; reading = entry.reading; accent = entry.accent; priority = entry.priority; editingID = entry.id; message = "" }
    func remove(_ entry: ReadingEntry) {
        do { try save(entries.filter { $0.id != entry.id }); if editingID == entry.id { reset() }; message = "削除しました。" }
        catch { message = error.localizedDescription }
    }
    func reset() { word = ""; reading = ""; accent = 0; priority = 5; editingID = nil }
}

struct DictionarySettingsView: View {
    @ObservedObject var dictionary: ReadingDictionary
    var checkPage: () -> Void = {}
    var preview: () -> Void = {}
    var body: some View {
        let candidates = Set(dictionary.pendingChecks.map(\.id))
        return VStack(alignment: .leading, spacing: 12) {
            TabView(selection: $dictionary.tab) {
                VStack(alignment: .leading, spacing: 10) {
                    HStack {
                        TextField("文字（例：ARTEX）", text: $dictionary.word).accessibilityLabel("文字")
                        Text("→")
                        TextField("読み（例：アルテックス）", text: $dictionary.reading).accessibilityLabel("読み")
                        Button(dictionary.editingID == nil ? "追加" : "更新") { dictionary.register() }.keyboardShortcut(.return, modifiers: [])
                        if dictionary.editingID != nil { Button("取消") { dictionary.reset() } }
                    }
                    HStack {
                        Stepper("アクセント：\(dictionary.accent)（0＝平板）", value: $dictionary.accent, in: 0...max(0, readingMoras(kanaReading(dictionary.reading))))
                        Stepper("優先度：\(dictionary.priority)", value: $dictionary.priority, in: 0...10)
                        Button(dictionary.previewing ? "試聴を停止" : "試聴") { preview() }
                            .disabled(!dictionary.previewing && (dictionary.word.isEmpty || dictionary.reading.isEmpty))
                    }.font(.callout)
                    if !dictionary.previewStatus.isEmpty { Text(dictionary.previewStatus).font(.caption).foregroundStyle(.secondary) }
                    ScrollView {
                        VStack(spacing: 0) {
                            ForEach(dictionary.entries) { entry in
                                HStack {
                                    Text(entry.word).frame(maxWidth: .infinity, alignment: .leading)
                                    Text("→").foregroundStyle(.secondary)
                                    Text(entry.reading).frame(maxWidth: .infinity, alignment: .leading)
                                    Button("編集") { dictionary.edit(entry) }
                                    Button { dictionary.remove(entry) } label: { Image(systemName: "trash") }.accessibilityLabel("\(entry.word)を削除")
                                }.padding(.vertical, 8)
                                Divider()
                            }
                            if dictionary.entries.isEmpty { Text("まだ登録されていません。").foregroundStyle(.secondary).padding(20) }
                        }.padding(8)
                    }.background(Color(nsColor: .textBackgroundColor)).cornerRadius(6)
                    Text(dictionary.message).font(.callout).foregroundStyle(.secondary).frame(minHeight: 20)
                }.padding(12).tabItem { Text("ワード追加・編集") }.tag(0)
                VStack(alignment: .leading, spacing: 10) {
                    HStack {
                        Button("現在のページの英単語を確認") { checkPage() }.disabled(dictionary.checking)
                        Spacer()
                    }
                    Text(dictionary.scanMessage).font(.callout).foregroundStyle(.secondary)
                    HStack {
                        Text("文字").frame(width: 130, alignment: .leading)
                        Text("現在の読み").frame(maxWidth: .infinity, alignment: .leading)
                        Text("登録する読み").frame(width: 190, alignment: .leading)
                    }.font(.caption).foregroundStyle(.secondary)
                    ScrollView {
                        VStack(spacing: 8) {
                            if !dictionary.checking && !dictionary.checks.isEmpty && candidates.isEmpty {
                                Text("未登録のアルファベット読み候補はありません。")
                                    .font(.callout).foregroundStyle(.secondary).padding(12)
                            }
                            ForEach($dictionary.checks) { $entry in
                                if candidates.contains(entry.id) {
                                    HStack {
                                        VStack(alignment: .leading) {
                                            Text(entry.word)
                                        }.frame(width: 130, alignment: .leading)
                                        Text(entry.reading.isEmpty ? "読み取得なし" : entry.reading).font(.callout).frame(maxWidth: .infinity, alignment: .leading)
                                        TextField("読みを入力", text: $entry.desiredReading).accessibilityLabel("\(entry.word)の登録する読み").frame(width: 190)
                                    }
                                }
                            }
                        }.padding(8)
                    }.background(Color(nsColor: .textBackgroundColor)).cornerRadius(6)
                    HStack {
                        Text("固有名詞の正しい読みは確認が必要です。").font(.caption).foregroundStyle(.secondary)
                        Spacer()
                        Button("入力した読みをまとめて登録") { dictionary.registerChecked() }.disabled(dictionary.checking)
                    }
                }.padding(12).tabItem { Text("ページの英単語") }.tag(1)
                VStack(alignment: .leading, spacing: 10) {
                    Toggle("起動時にGitHubの共通辞書を更新", isOn: $dictionary.autoUpdate)
                    HStack {
                        Button("今すぐ更新") { dictionary.updateCommon() }.disabled(dictionary.updating)
                        Spacer()
                        Button("JSONを取り込む") { dictionary.chooseImport() }
                        Button("個人辞書を書き出す") { dictionary.chooseExport() }
                    }
                    Text(dictionary.commonStatus).font(.callout).foregroundStyle(.secondary)
                    TextField("共通辞書を検索", text: $dictionary.commonSearch)
                    HStack {
                        Text("文字").frame(width: 180, alignment: .leading)
                        Text("読み").frame(maxWidth: .infinity, alignment: .leading)
                        Text("アクセント").frame(width: 70, alignment: .center)
                        Color.clear.frame(width: 82, height: 1)
                    }.font(.caption).foregroundStyle(.secondary).padding(.horizontal, 8)
                    ScrollView {
                        LazyVStack(spacing: 6) {
                            ForEach(dictionary.commonEntries.filter { dictionary.commonSearch.isEmpty || $0.word.localizedCaseInsensitiveContains(dictionary.commonSearch) || $0.reading.contains(dictionary.commonSearch) }) { entry in
                                HStack {
                                    Text(entry.word).frame(width: 180, alignment: .leading)
                                    Text(entry.reading).frame(maxWidth: .infinity, alignment: .leading)
                                    Text("\(entry.accent)").monospacedDigit().frame(width: 70, alignment: .center)
                                    Button("読みを修正") { dictionary.reset(); dictionary.word = entry.word; dictionary.reading = entry.reading; dictionary.accent = entry.accent; dictionary.priority = entry.priority; dictionary.tab = 0 }.frame(width: 82)
                                }
                            }
                        }.padding(8)
                    }.background(Color(nsColor: .textBackgroundColor)).cornerRadius(6)
                    Text("共通辞書より個人登録を優先します。通信は公開JSONの取得のみで、本文・URL・個人辞書を送信しません。")
                        .font(.caption).foregroundStyle(.secondary)
                }.padding(12).tabItem { Text("共通辞書・JSON") }.tag(2)
            }
            Text("英字の大文字・小文字は区別しません。辞書はこのMacに保存し、RTranslateの辞書は変更しません。")
                .font(.caption).foregroundStyle(.secondary)
        }.padding(20).frame(width: 680, height: 490)
    }
}

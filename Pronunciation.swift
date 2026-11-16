import Foundation
import SwiftUI

struct ReadingEntry: Codable, Identifiable, Equatable, Sendable {
    var id: UUID = UUID()
    var word: String
    var reading: String
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

struct WordCheck: Decodable, Identifiable, Sendable {
    var id: String { word }
    let word: String
    let reading: String
    let isSpelling: Bool
    var desiredReading = ""
    enum CodingKeys: String, CodingKey { case word, reading, isSpelling }
}
func englishWords(_ text: String) -> [String] {
    let regex = try! NSRegularExpression(pattern: "(?<![A-Za-z0-9_])[A-Za-z][A-Za-z0-9]*(?:[-'][A-Za-z0-9]+)*(?![A-Za-z0-9_])")
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
    @Published var message = ""
    @Published var tab = 0
    @Published var checks: [WordCheck] = []
    @Published var checking = false
    @Published var scanMessage = "現在のSafariページの英単語を調べられます。"
    @Published var onlySpelling = true
    private let defaults: UserDefaults
    private let key = "readingDictionaryV1"
    private var writable = true
    var onChange: (() -> Void)?
    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        if let data = defaults.data(forKey: key) {
            do { entries = try JSONDecoder().decode([ReadingEntry].self, from: data) }
            catch { writable = false; message = "保存済みの辞書を読み込めません。元データを保護するため変更を保存しません。" }
        }
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
            let kana = reading.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !term.isEmpty, !kana.isEmpty, term.count <= 64, kana.count <= 64,
                  term.rangeOfCharacter(from: .newlines) == nil, kana.rangeOfCharacter(from: .newlines) == nil else {
                throw ReaderError(message: "文字と読みをそれぞれ1〜64文字で入力してください。改行は使えません。")
            }
            var updated = entries
            let existing = editingID.flatMap { id in updated.firstIndex(where: { $0.id == id }) }
                ?? updated.firstIndex(where: { $0.word.compare(term, options: .caseInsensitive) == .orderedSame })
            if let index = existing {
                let id = updated[index].id
                guard !updated.contains(where: { $0.id != id && $0.word.compare(term, options: .caseInsensitive) == .orderedSame }) else {
                    throw ReaderError(message: "同じ文字がすでに登録されています。")
                }
                updated[index] = ReadingEntry(id: id, word: term, reading: kana)
            } else {
                guard updated.count < 100 else { throw ReaderError(message: "辞書は100件まで登録できます。") }
                updated.append(ReadingEntry(word: term, reading: kana))
            }
            try save(updated)
            reset(); message = "登録しました。変更は次の文から反映されます。"
        } catch { message = error.localizedDescription }
    }
    func registerChecked() {
        do {
            let additions = checks.filter { !$0.desiredReading.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
            guard !additions.isEmpty else { scanMessage = "登録する読みを入力してください。"; return }
            var updated = entries
            for addition in additions {
                let reading = addition.desiredReading.trimmingCharacters(in: .whitespacesAndNewlines)
                guard reading.count <= 64, reading.rangeOfCharacter(from: .newlines) == nil else {
                    throw ReaderError(message: "読みは1〜64文字、改行なしで入力してください。")
                }
                if let index = updated.firstIndex(where: { $0.word.compare(addition.word, options: .caseInsensitive) == .orderedSame }) {
                    updated[index].reading = reading
                } else {
                    updated.append(ReadingEntry(word: addition.word, reading: reading))
                }
            }
            guard updated.count <= 100 else { throw ReaderError(message: "辞書は100件まで登録できます。") }
            try save(updated)
            for index in checks.indices { checks[index].desiredReading = "" }
            scanMessage = "\(additions.count)件を登録しました。変更は次の文から反映されます。"
        } catch { scanMessage = error.localizedDescription }
    }
    func edit(_ entry: ReadingEntry) { word = entry.word; reading = entry.reading; editingID = entry.id; message = "" }
    func remove(_ entry: ReadingEntry) {
        do { try save(entries.filter { $0.id != entry.id }); if editingID == entry.id { reset() }; message = "削除しました。" }
        catch { message = error.localizedDescription }
    }
    func reset() { word = ""; reading = ""; editingID = nil }
}

struct DictionarySettingsView: View {
    @ObservedObject var dictionary: ReadingDictionary
    var checkPage: () -> Void = {}
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("読み上げ辞書").font(.title2.bold())
            Text("表示を変えず、読み上げるときだけ読み方を変更します。声・速度・辞書の変更は次の文から反映されます。")
                .font(.callout).foregroundStyle(.secondary)
            TabView(selection: $dictionary.tab) {
                VStack(alignment: .leading, spacing: 10) {
                    HStack {
                        TextField("文字（例：ARTEX）", text: $dictionary.word).accessibilityLabel("文字")
                        Text("→")
                        TextField("読み（例：アルテックス）", text: $dictionary.reading).accessibilityLabel("読み")
                        Button(dictionary.editingID == nil ? "追加" : "更新") { dictionary.register() }.keyboardShortcut(.return, modifiers: [])
                        if dictionary.editingID != nil { Button("取消") { dictionary.reset() } }
                    }
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
                        Toggle("綴り読み候補のみ", isOn: $dictionary.onlySpelling).toggleStyle(.checkbox)
                        Spacer()
                    }
                    Text(dictionary.scanMessage).font(.callout).foregroundStyle(.secondary)
                    HStack {
                        Text("文字").frame(width: 130, alignment: .leading)
                        Text("VOICEVOX標準の読み").frame(maxWidth: .infinity, alignment: .leading)
                        Text("登録する読み").frame(width: 190, alignment: .leading)
                    }.font(.caption).foregroundStyle(.secondary)
                    ScrollView {
                        VStack(spacing: 8) {
                            ForEach($dictionary.checks) { $entry in
                                if !dictionary.onlySpelling || entry.isSpelling {
                                    HStack {
                                        VStack(alignment: .leading) {
                                            Text(entry.word)
                                            if dictionary.entries.contains(where: { $0.word.compare(entry.word, options: .caseInsensitive) == .orderedSame }) {
                                                Text("登録済み").font(.caption2).foregroundStyle(.secondary)
                                            }
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
            }
            Text("英字の大文字・小文字は区別しません。辞書はこのMacに保存し、RTranslateの辞書は変更しません。")
                .font(.caption).foregroundStyle(.secondary)
        }.padding(20).frame(width: 680, height: 490)
    }
}

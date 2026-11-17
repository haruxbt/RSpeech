actor FakeSafari: SafariSource {
    var url = "https://example.test/a"
    var text = "最初の本文です。"
    var fail = false
    var pageCalls = 0
    var wholePageCalls = 0
    var delay: UInt64 = 0
    var documentID: String?
    var selectionID: String?
    func currentURL() async throws -> String { url }
    func position() async throws -> PagePosition { PagePosition(url: url, documentID: documentID, selectionID: selectionID) }
    func page() async throws -> Page {
        pageCalls += 1
        let snapshot = Page(url: url, text: text, documentID: documentID, selectionID: selectionID)
        if delay > 0 { try await Task.sleep(nanoseconds: delay) }
        if fail { throw ReaderError(message: "fixture fetch failed") }
        return snapshot
    }
    func wholePage() async throws -> Page {
        wholePageCalls += 1
        throw ReaderError(message: "Word collection must use playback extraction")
    }
    func set(_ url: String, _ text: String, fail: Bool = false, delay: UInt64 = 0, documentID: String? = nil, selectionID: String? = nil) {
        self.url = url; self.text = text; self.fail = fail; self.delay = delay; self.documentID = documentID; self.selectionID = selectionID
    }
}
final class FakeSpeech: SpeechEngine, @unchecked Sendable {
    let onRequest: @MainActor @Sendable (String, Int, Double) -> Void
    init(onRequest: @escaping @MainActor @Sendable (String, Int, Double) -> Void = { _, _, _ in }) { self.onRequest = onRequest }
    func start() async throws -> [Voice] { [Voice(id: 2, name: "四国めたん")] }
    func close() {}
    func analyze(words: [String], dictionary: [ReadingEntry]) async throws -> [WordCheck] {
        words.map { WordCheck(word: $0, reading: "テスト", isSpelling: false) }
    }
    func synthesize(_ text: String, speaker: Int, speed: Double, dictionary: [ReadingEntry]) async throws -> Data {
        await onRequest(pronunciation(text, entries: dictionary), speaker, speed)
        try await Task.sleep(nanoseconds: 150_000_000)
        // Two seconds of silence, used only in memory for playback state tests.
        var data = Data()
        func string(_ s: String) { data.append(contentsOf: s.utf8) }
        func number<T: FixedWidthInteger>(_ n: T) { var value = n.littleEndian; withUnsafeBytes(of: &value) { data.append(contentsOf: $0) } }
        string("RIFF"); number(UInt32(96036)); string("WAVEfmt "); number(UInt32(16)); number(UInt16(1)); number(UInt16(1)); number(UInt32(24000)); number(UInt32(48000)); number(UInt16(2)); number(UInt16(16)); string("data"); number(UInt32(96000)); data.append(Data(count: 96000))
        return data
    }
}
@MainActor func waitFor(_ condition: () -> Bool, line: UInt = #line) async throws {
    let deadline = Date().addingTimeInterval(8)
    while !condition() {
        if Date() > deadline { throw ReaderError(message: "Timed out waiting for reader state at line \(line)") }
        try await Task.sleep(nanoseconds: 10_000_000)
    }
}
@MainActor func readerChecks() async throws {
    let suite = "RSpeechChecks-" + UUID().uuidString
    let preferences = UserDefaults(suiteName: suite)!
    defer { preferences.removePersistentDomain(forName: suite) }
    let dictionary = ReadingDictionary(defaults: preferences)
    dictionary.word = "ARTEX"; dictionary.reading = "アルテックス"; dictionary.register()
    precondition(dictionary.entries.count == 1)
    precondition(ReadingDictionary(defaults: preferences).entries == dictionary.entries, "Dictionary must survive relaunch")
    precondition(pronunciation("ARTEXとartex。SMARTEXはそのまま。", entries: dictionary.entries) == "アルテックスとアルテックス。SMARTEXはそのまま。")
    precondition(pronunciation("ARTEX API", entries: [ReadingEntry(word: "ARTEX", reading: "API"), ReadingEntry(word: "API", reading: "エーピーアイ")]) == "API エーピーアイ", "Replacements must not cascade")
    dictionary.word = "ARTEX"; dictionary.reading = "アルテクス"; dictionary.register()
    precondition(dictionary.entries.count == 1 && dictionary.entries[0].reading == "アルテクス")
    dictionary.remove(dictionary.entries[0]); precondition(ReadingDictionary(defaults: preferences).entries.isEmpty)
    dictionary.word = "  "; dictionary.reading = "空白"; dictionary.register(); precondition(dictionary.entries.isEmpty)
    precondition(englishWords("ARTEXとartex、LinuxやAPI。") == ["ARTEX", "Linux", "API"])
    dictionary.checks = [WordCheck(word: "ARTEX", reading: "エエアアルティイイイエックス", isSpelling: true, desiredReading: "アルテックス"), WordCheck(word: "Linux", reading: "リナックス", isSpelling: false, desiredReading: "リナックス")]
    dictionary.registerChecked()
    precondition(dictionary.entries.count == 2)
    precondition(ReadingDictionary(defaults: preferences).entries.count == 2)
    let originalEntries = dictionary.entries
    dictionary.checks = [WordCheck(word: "ARTEX", reading: "", isSpelling: true, desiredReading: "更新した読み"), WordCheck(word: "API", reading: "", isSpelling: true, desiredReading: String(repeating: "ア", count: 65))]
    dictionary.registerChecked(); precondition(dictionary.entries == originalEntries, "Bulk registration must be atomic")
    dictionary.edit(dictionary.entries.first(where: { $0.word == "ARTEX" })!)
    dictionary.word = "Linux"; dictionary.reading = "誤更新"; dictionary.register()
    precondition(dictionary.entries == originalEntries, "Editing into a duplicate must preserve both entries")
    dictionary.reset()
    let fixture = CommonDictionaryFile(schemaVersion: 1, version: "1.0", entries: [ReadingEntry(word: "PUT", reading: "プット"), ReadingEntry(word: "ARTEX", reading: "アルテックス", accent: 1)])
    let commonData = try JSONEncoder().encode(fixture)
    try dictionary.applyCommon(commonData, persist: false)
    precondition(dictionary.effectiveEntries.contains(where: { $0.word == "PUT" }))
    precondition(dictionary.effectiveEntries.filter { $0.word.lowercased() == "artex" }.count == 1)
    precondition(dictionary.effectiveEntries.first(where: { $0.word.lowercased() == "artex" })?.id == dictionary.entries.first(where: { $0.word == "ARTEX" })?.id, "Personal entries must override shared ones")
    try dictionary.importJSON(try JSONEncoder().encode([ReadingEntry(word: "POST", reading: "ポスト", accent: 1, priority: 7)]))
    precondition(dictionary.entries.contains(where: { $0.word == "POST" && $0.accent == 1 && $0.priority == 7 }))
    let engineJSON = Data(#"{"test-id":{"surface":"ＧＥＴ","pronunciation":"ゲット","accent_type":1,"priority":5}}"#.utf8)
    try dictionary.importJSON(engineJSON)
    precondition(dictionary.entries.contains(where: { $0.word == "GET" && $0.reading == "ゲット" }))
    let exported = try dictionary.exportJSON()
    let exportedEntries = try decodeImportedReadings(exported)
    precondition(exportedEntries == dictionary.entries)
    let versionBefore = dictionary.commonVersion
    do { try dictionary.applyCommon(Data("{}".utf8), persist: false); preconditionFailure("Invalid remote data accepted") } catch {}
    precondition(dictionary.commonVersion == versionBefore, "Invalid update must retain cached data")
    do { try dictionary.applyCommon(try JSONEncoder().encode(CommonDictionaryFile(schemaVersion: 1, version: "0.9", entries: [])), persist: false); preconditionFailure("Downgrade accepted") } catch {}
    let cacheDirectory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: cacheDirectory) }
    let cacheURL = cacheDirectory.appendingPathComponent("common.json")
    let cached = ReadingDictionary(defaults: preferences, cacheURL: cacheURL)
    try cached.applyCommon(commonData)
    precondition(ReadingDictionary(defaults: preferences, cacheURL: cacheURL).commonVersion == "1.0", "Offline cache must load on restart")
    let cleanupPreferences = UserDefaults(suiteName: suite + "cleanup")!
    defer { cleanupPreferences.removePersistentDomain(forName: suite + "cleanup") }
    let cleanup = ReadingDictionary(defaults: cleanupPreferences, cacheURL: cacheDirectory.appendingPathComponent("cleanup.json"))
    try cleanup.importJSON(try JSONEncoder().encode([
        ReadingEntry(word: "Match", reading: "まっち", accent: 1),
        ReadingEntry(word: "Accent", reading: "アクセント", accent: 2),
        ReadingEntry(word: "Priority", reading: "プライオリティ", priority: 9),
        ReadingEntry(word: "Reading", reading: "リーディング"),
        ReadingEntry(word: "Private", reading: "プライベート")]))
    let cleanupData = try JSONEncoder().encode(CommonDictionaryFile(schemaVersion: 1, version: "2.0", entries: [
        ReadingEntry(word: "MATCH", reading: "マッチ", accent: 1),
        ReadingEntry(word: "Accent", reading: "アクセント", accent: 0),
        ReadingEntry(word: "Priority", reading: "プライオリティ", priority: 5),
        ReadingEntry(word: "Reading", reading: "リード")]))
    try cleanup.applyCommon(cleanupData)
    precondition(cleanup.entries.count == 4 && !cleanup.entries.contains(where: { $0.word == "Match" }))
    precondition(cleanup.effectiveEntries.first(where: { $0.word == "Accent" })?.accent == 2)
    precondition(cleanup.effectiveEntries.first(where: { $0.word == "Priority" })?.priority == 9)
    precondition(ReadingDictionary(defaults: cleanupPreferences, cacheURL: cacheDirectory.appendingPathComponent("cleanup.json")).entries.count == 4)
    // A cached dictionary also deduplicates on launch, before any network update.
    try cleanup.importJSON(try JSONEncoder().encode([ReadingEntry(word: "Match", reading: "マッチ", accent: 1)]))
    precondition(ReadingDictionary(defaults: cleanupPreferences, cacheURL: cacheDirectory.appendingPathComponent("cleanup.json")).entries.count == 4)
    print("Matching personal entries removed and persisted; differing reading/accent/priority and private words retained")
    print("Common JSON validation, personal override, import/export, engine JSON, cache restart and rollback checks passed")
    let source = FakeSafari()
    let reader = Reader(safari: source, muted: true, dictionary: dictionary, preferences: preferences, makeEngine: { FakeSpeech() })
    reader.toggle()
    try await waitFor { reader.busy && !reader.fetching }
    precondition(reader.text == "最初の本文です。")
    precondition(reader.buttonSymbol == "pause.fill")
    reader.toggle()
    precondition(reader.paused && reader.buttonSymbol == "play.fill")
    reader.toggle()
    try await waitFor { !reader.paused && !reader.fetching }
    let firstCount = await source.pageCalls; precondition(firstCount == 1, "Same URL must reuse the page")
    reader.toggle()
    await source.set("https://example.test/b", "二番目の本文です。")
    reader.toggle()
    try await waitFor { reader.busy && !reader.fetching && reader.pageURL == "https://example.test/b" }
    precondition(reader.text == "二番目の本文です。" && !reader.text.contains("最初"))
    let secondCount = await source.pageCalls; precondition(secondCount == 2)
    reader.toggle()
    await source.set("https://example.test/c", "取得失敗", fail: true)
    reader.toggle()
    try await waitFor { !reader.fetching }
    precondition(reader.text.isEmpty && reader.pageURL == nil && !reader.busy, "Failed new page must clear old speech")
    await source.set("https://example.test/d", "停止中に取得した本文", delay: 300_000_000)
    reader.toggle()
    try await Task.sleep(nanoseconds: 50_000_000)
    reader.stop()
    try await Task.sleep(nanoseconds: 400_000_000)
    precondition(reader.text.isEmpty && !reader.busy, "Canceled fetch must not resurrect playback")
    await source.set("https://example.test/e", "ページ変更前の本文", delay: 150_000_000)
    reader.toggle()
    try await Task.sleep(nanoseconds: 50_000_000)
    await source.set("https://example.test/f", "ページ変更後の本文")
    try await waitFor { !reader.fetching }
    precondition(reader.text.isEmpty && !reader.busy, "Navigation during extraction must not cache stale content")
    reader.stop()
    let selectedSource = FakeSafari()
    await selectedSource.set("https://example.test/selected", "選択した位置からの本文。", documentID: "doc1", selectionID: "sel1")
    let selectedReader = Reader(safari: selectedSource, muted: true, preferences: preferences, makeEngine: { FakeSpeech() })
    selectedReader.toggle(); try await waitFor { selectedReader.busy && !selectedReader.fetching }
    selectedReader.toggle(); selectedReader.toggle(); try await waitFor { !selectedReader.paused && !selectedReader.fetching }
    let unchangedCount = await selectedSource.pageCalls; precondition(unchangedCount == 1)
    selectedReader.toggle()
    await selectedSource.set("https://example.test/selected", "別の選択位置から。", documentID: "doc1", selectionID: "sel2")
    selectedReader.toggle(); try await waitFor { !selectedReader.fetching && selectedReader.text == "別の選択位置から。" }
    let changedCount = await selectedSource.pageCalls; precondition(changedCount == 2)
    selectedReader.toggle()
    await selectedSource.set("https://example.test/selected", "全体の本文。", documentID: "doc1")
    selectedReader.toggle(); try await waitFor { !selectedReader.paused && !selectedReader.fetching }
    precondition(selectedReader.text == "別の選択位置から。", "Clearing selection during pause must preserve resume")
    selectedReader.stop(); selectedReader.toggle()
    try await waitFor { !selectedReader.fetching && selectedReader.text == "全体の本文。" }
    selectedReader.toggle()
    await selectedSource.set("https://example.test/selected", "再読込した本文。", documentID: "doc2")
    selectedReader.toggle(); try await waitFor { !selectedReader.fetching && selectedReader.text == "再読込した本文。" }
    selectedReader.stop()
    await selectedSource.set("https://example.test/selected", "古い選択。", delay: 150_000_000, documentID: "doc2", selectionID: "sel3")
    selectedReader.toggle(); try await Task.sleep(nanoseconds: 50_000_000)
    await selectedSource.set("https://example.test/selected", "新しい選択。", documentID: "doc2", selectionID: "sel4")
    try await waitFor { !selectedReader.fetching }
    precondition(selectedReader.text.isEmpty && !selectedReader.busy)
    selectedReader.stop()
    print("Selection resume, same-URL reselection, clear, document reload and selection-race checks passed")
    let previewDictionary = ReadingDictionary(defaults: cleanupPreferences)
    previewDictionary.word = "Preview"; previewDictionary.reading = "プレビュー"; previewDictionary.accent = 2
    let savedBeforePreview = previewDictionary.entries
    var previewRequests: [(String, Int, Double, Bool)] = []
    var previewReader: Reader!
    previewReader = Reader(safari: FakeSafari(), muted: true, dictionary: previewDictionary, preferences: preferences, makeEngine: {
        FakeSpeech { text, voice, rate in previewRequests.append((text, voice, rate, previewReader.isAudioPlaying)) }
    })
    previewReader.toggle(); try await waitFor { previewReader.isAudioPlaying }
    previewReader.previewPronunciation()
    precondition(previewReader.paused)
    try await waitFor { previewReader.isPreviewAudioPlaying }
    precondition(previewRequests.last!.0 == "プレビュー" && !previewRequests.last!.3)
    precondition(previewDictionary.entries == savedBeforePreview, "Audition must never register the draft")
    previewReader.toggle(); try await waitFor { !previewReader.paused && !previewReader.fetching }
    precondition(!previewReader.isPreviewAudioPlaying && !previewDictionary.previewing)
    previewReader.stop()
    previewReader.previewPronunciation(); previewReader.stopPronunciationPreview()
    try await Task.sleep(nanoseconds: 250_000_000)
    precondition(!previewReader.isPreviewAudioPlaying && !previewDictionary.previewing)
    print("Accent audition passes draft to synthesis without saving, pauses playback and cancels before resume")
    let wordSource = FakeSafari()
    let wordDictionary = ReadingDictionary(defaults: preferences)
    precondition(!wordDictionary.onlySpelling, "Collected words must be visible by default")
    let wordReader = Reader(safari: wordSource, muted: true, dictionary: wordDictionary, preferences: preferences, makeEngine: { FakeSpeech() })
    await wordSource.set("https://example.test/words", "ARTEXとLinux、APIを確認。", documentID: "words", selectionID: "start")
    wordReader.checkPageWords(); try await waitFor { !wordDictionary.checking }
    precondition(Set(wordDictionary.checks.map(\.word)) == Set(["ARTEX", "Linux", "API"]))
    wordReader.toggle(); try await waitFor { !wordReader.fetching && wordReader.busy }
    wordReader.toggle()
    let callsBeforeScan = await wordSource.pageCalls
    wordReader.checkPageWords(); try await waitFor { !wordDictionary.checking }
    let callsAfterScan = await wordSource.pageCalls
    precondition(callsBeforeScan == callsAfterScan, "Word collection must reuse the exact playback text")
    precondition(Set(wordDictionary.checks.map(\.word)) == Set(englishWords(wordReader.text)))
    await wordSource.set("https://example.test/words", "CiscoとWiz。", documentID: "words", selectionID: "new")
    wordReader.checkPageWords(); try await waitFor { !wordDictionary.checking }
    precondition(Set(wordDictionary.checks.map(\.word)) == Set(["Cisco", "Wiz"]), "New selection uses the same selection-aware page method as play")
    await wordSource.set("https://example.test/no-words", "日本語のみ。", documentID: "no-words")
    wordReader.checkPageWords(); try await waitFor { !wordDictionary.checking }
    precondition(wordDictionary.checks.isEmpty && wordDictionary.scanMessage.contains("見つかりません"))
    await wordSource.set("https://example.test/failing", "GET", fail: true)
    wordReader.checkPageWords(); try await waitFor { !wordDictionary.checking }
    precondition(wordDictionary.checks.isEmpty && wordDictionary.scanMessage.contains("fixture fetch failed"))
    let unusedWholePage = await wordSource.wholePageCalls; precondition(unusedWholePage == 0)
    wordReader.stop()
    print("Word scan shares playback extraction/cache/selection, shows registered words, clears stale results and reports empty/error states")
    // Observe the actual AVAudioPlayer state when the next synthesis starts.
    let pipelineSource = FakeSafari()
    let first = "最初の文章を読みながら次の音声を準備するための確認です。"
    let second = "ARTEXを二番目の文章として読み上げるための確認です。"
    let third = "最後の文章まで正しい順序で再生することを確認します。"
    await pipelineSource.set("https://example.test/pipeline", first + second + third)
    precondition(chunks(first + second + third).count == 3)
    var active: Reader?
    var requests: [(text: String, speaker: Int, speed: Double, duringPlayback: Bool)] = []
    let spy = FakeSpeech { text, speaker, speed in requests.append((text, speaker, speed, active?.isAudioPlaying ?? false)) }
    let pipeline = Reader(safari: pipelineSource, muted: true, dictionary: ReadingDictionary(defaults: preferences), preferences: preferences, makeEngine: { spy })
    active = pipeline
    pipeline.toggle()
    try await waitFor { requests.count >= 2 }
    precondition(requests[1].duringPlayback, "Next sentence must synthesize while the current sentence is playing")
    precondition(pipeline.text == first + second + third)
    pipeline.speaker = 3; pipeline.speed = 1.5
    pipeline.dictionary.word = "ARTEX"; pipeline.dictionary.reading = "アルテックス"; pipeline.dictionary.register()
    try await waitFor { requests.contains(where: { $0.text.contains("アルテックス") && $0.speaker == 3 && $0.speed == 1.5 }) }
    precondition(pipeline.text.contains("ARTEX"), "Dictionary must not change displayed page text")
    pipeline.toggle(); precondition(pipeline.paused)
    pipeline.speaker = 8; pipeline.speed = 2
    try await waitFor { requests.contains(where: { $0.text.contains("アルテックス") && $0.speaker == 8 && $0.speed == 2 }) }
    pipeline.toggle()
    try await waitFor { !pipeline.paused && !pipeline.fetching }
    try await waitFor { requests.contains(where: { $0.text == third }) }
    try await waitFor { !pipeline.busy }
    precondition(preferences.integer(forKey: "speaker") == 8 && preferences.double(forKey: "speed") == 2)
    pipeline.stop(); pipeline.speaker = 2; pipeline.speed = 1.2
    precondition(!pipeline.busy)
    if CommandLine.arguments.contains("--network") {
        let online = ReadingDictionary(defaults: preferences, cacheURL: cacheDirectory.appendingPathComponent("download.json"))
        online.updateCommon()
        let deadline = Date().addingTimeInterval(25)
        while online.updating && Date() < deadline { try await Task.sleep(nanoseconds: 100_000_000) }
        precondition(online.commonEntries.count >= 789, online.commonStatus)
        precondition(online.commonEntries.contains(where: { $0.word == "Intent" && $0.reading == "インテント" }))
        precondition(online.commonEntries.contains(where: { $0.word == "Attack Surface" && $0.reading == "アタックサーフェス" }))
        precondition(online.commonEntries.contains(where: { $0.word == "Tor" && $0.reading == "トア" }))
        print("Live GitHub JSON fetch, validation and cache write passed")
    }
    print("Dictionary persistence/update/delete, non-cascading readings, playback overlap, live voice/speed/dictionary invalidation passed")
    print("Reader checks passed: one-button playback, preparation pause/resume, same-URL reuse, new-URL replacement, fetch failure, cancel, navigation race")
}
MainActor.assumeIsolated {
    Task { @MainActor in
        do { try await readerChecks(); exit(0) }
        catch { print(error.localizedDescription); exit(1) }
    }
    RunLoop.main.run()
}

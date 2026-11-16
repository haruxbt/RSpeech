actor FakeSafari: SafariSource {
    var url = "https://example.test/a"
    var text = "最初の本文です。"
    var fail = false
    var pageCalls = 0
    var delay: UInt64 = 0
    func currentURL() async throws -> String { url }
    func page() async throws -> Page {
        pageCalls += 1
        let snapshot = Page(url: url, text: text)
        if delay > 0 { try await Task.sleep(nanoseconds: delay) }
        if fail { throw ReaderError(message: "fixture fetch failed") }
        return snapshot
    }
    func set(_ url: String, _ text: String, fail: Bool = false, delay: UInt64 = 0) {
        self.url = url; self.text = text; self.fail = fail; self.delay = delay
    }
}
final class FakeSpeech: SpeechEngine, @unchecked Sendable {
    func start() async throws -> [Voice] { [Voice(id: 2, name: "四国めたん")] }
    func close() {}
    func synthesize(_ text: String, speaker: Int, speed: Double) async throws -> Data {
        try await Task.sleep(nanoseconds: 150_000_000)
        // Two seconds of silence, used only in memory for playback state tests.
        var data = Data()
        func string(_ s: String) { data.append(contentsOf: s.utf8) }
        func number<T: FixedWidthInteger>(_ n: T) { var value = n.littleEndian; withUnsafeBytes(of: &value) { data.append(contentsOf: $0) } }
        string("RIFF"); number(UInt32(96036)); string("WAVEfmt "); number(UInt32(16)); number(UInt16(1)); number(UInt16(1)); number(UInt32(24000)); number(UInt32(48000)); number(UInt16(2)); number(UInt16(16)); string("data"); number(UInt32(96000)); data.append(Data(count: 96000))
        return data
    }
}
@MainActor func waitFor(_ condition: () -> Bool) async throws {
    let deadline = Date().addingTimeInterval(4)
    while !condition() {
        if Date() > deadline { throw ReaderError(message: "Timed out waiting for reader state") }
        try await Task.sleep(nanoseconds: 10_000_000)
    }
}
@MainActor func readerChecks() async throws {
    let source = FakeSafari()
    let reader = Reader(safari: source, muted: true, makeEngine: { FakeSpeech() })
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
    print("Reader checks passed: one-button playback, preparation pause/resume, same-URL reuse, new-URL replacement, fetch failure, cancel, navigation race")
}
MainActor.assumeIsolated {
    Task { @MainActor in
        do { try await readerChecks(); exit(0) }
        catch { print(error.localizedDescription); exit(1) }
    }
    RunLoop.main.run()
}

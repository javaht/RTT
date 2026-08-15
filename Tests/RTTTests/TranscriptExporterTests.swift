import Testing
@testable import RTT

struct TranscriptExporterTests {
    @Test
    func testSRTExportsOrderedBilingualEntriesWithTimestamps() {
        let entries = [
            TranslationEntry(
                orderID: 0,
                source: "Bonjour.",
                target: "你好。",
                startTime: 1.234,
                endTime: 3.456
            ),
            TranslationEntry(
                orderID: 1,
                source: "Au revoir.",
                target: "再见。",
                startTime: 4,
                endTime: 5.25
            ),
        ]

        #expect(
            TranscriptExporter.srt(entries: entries) == """
            1
            00:00:01,234 --> 00:00:03,456
            Bonjour.
            你好。

            2
            00:00:04,000 --> 00:00:05,250
            Au revoir.
            再见。
            """
        )
    }

    @Test
    func testTXTExportsBilingualParagraphs() {
        let entries = [
            TranslationEntry(orderID: 0, source: "Hello.", target: "你好。"),
            TranslationEntry(orderID: 0, source: "Thanks.", target: "谢谢。"),
        ]

        #expect(TranscriptExporter.txt(entries: entries) == "Hello.\n你好。\n\nThanks.\n谢谢。")
    }

    @Test
    func testTranslationFailureExportsOnlyOriginalText() {
        let entry = TranslationEntry(
            orderID: 0,
            source: "Original text.",
            target: "⚠️ 翻译失败（无结果）",
            startTime: 2,
            endTime: 2
        )

        #expect(
            TranscriptExporter.srt(entries: [entry]) == """
            1
            00:00:02,000 --> 00:00:02,100
            Original text.
            """
        )
        #expect(TranscriptExporter.txt(entries: [entry]) == "Original text.")
    }

    @Test
    func testEmptyExportProducesEmptyFile() {
        #expect(TranscriptExporter.srt(entries: []) == "")
        #expect(TranscriptExporter.txt(entries: []) == "")
    }
}

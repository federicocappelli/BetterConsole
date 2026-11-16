import Foundation
import Testing
import UniformTypeIdentifiers

@Suite struct LogFileTextTests {
    @Test func loading() {
        #expect(LogFileText.loading(progress: 0) == "Loading… 0%")
        #expect(LogFileText.loading(progress: 0.454) == "Loading… 45%")
        #expect(LogFileText.loading(progress: 0.999) == "Loading… 99%")
        #expect(LogFileText.loading(progress: 1) == "Loading… 100%")
        #expect(LogFileText.loading(progress: 7) == "Loading… 100%")
    }

    @Test func memoryLimit() {
        #expect(
            LogFileText.memoryLimit(kept: 45_348, locale: Locale(identifier: "en_US"))
                == "Only the newest 45,348 messages fit in the memory limit (Settings)")
    }

    /// Open… offers logs, plain text and JSON lines.
    @Test func openableTypes() {
        let types = LogFileText.openableTypes
        for ext in ["log", "txt", "ndjson", "jsonl"] {
            let type = UTType(filenameExtension: ext)!
            #expect(types.contains { type.conforms(to: $0) }, "\(ext)")
        }
        #expect(!types.contains { UTType.png.conforms(to: $0) })
    }
}

@Suite struct LogFileTextNoneKeptTests {
    @Test func memoryLimitWithNothingKept() {
        #expect(LogFileText.memoryLimit(kept: 0) == "None of this file's messages fit in the memory limit (Settings).")
    }
}

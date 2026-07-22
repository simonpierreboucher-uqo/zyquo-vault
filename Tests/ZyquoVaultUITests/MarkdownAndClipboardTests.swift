import AppKit
import Foundation
import Testing
@testable import ZyquoVaultUI

@Suite("Markdown note parser")
struct MarkdownParserTests {

    @Test func parsesAllBlockKinds() {
        let source = """
        # Title
        ## Section
        Plain paragraph with **bold**.
        - bullet one
        * bullet two
        1. first
        2. second
        - [ ] open task
        - [x] done task
        > a quote
        ---
        ```
        let code = true
        ```
        """
        let blocks = MarkdownNoteView.parse(source)
        #expect(blocks[0] == .heading(level: 1, text: "Title"))
        #expect(blocks[1] == .heading(level: 2, text: "Section"))
        #expect(blocks[2] == .paragraph("Plain paragraph with **bold**."))
        #expect(blocks[3] == .bullet("bullet one"))
        #expect(blocks[4] == .bullet("bullet two"))
        #expect(blocks[5] == .numbered(1, "first"))
        #expect(blocks[6] == .numbered(2, "second"))
        #expect(blocks[7] == .checklist(done: false, text: "open task"))
        #expect(blocks[8] == .checklist(done: true, text: "done task"))
        #expect(blocks[9] == .quote("a quote"))
        #expect(blocks[10] == .rule)
        #expect(blocks[11] == .code(["let code = true"]))
    }

    @Test func neverCrashesOnHostileInput() {
        let hostile = [
            "",
            "```", // unterminated fence
            "#######", // too many hashes → paragraph
            "<script>alert(1)</script>", // rendered as text, never executed
            "![img](https://evil.example/x.png)", // no image loading exists
            String(repeating: "> \n- [x] \n```\n", count: 500),
        ]
        for input in hostile {
            _ = MarkdownNoteView.parse(input) // must simply not crash
        }
        // Script/HTML stays inert text.
        let blocks = MarkdownNoteView.parse("<script>alert(1)</script>")
        #expect(blocks == [.paragraph("<script>alert(1)</script>")])
    }
}

@Suite("Clipboard manager", .serialized)
@MainActor
struct ClipboardManagerTests {

    /// Preserves whatever the user had on the clipboard around each test.
    func withPreservedPasteboard(_ body: () async throws -> Void) async rethrows {
        let saved = NSPasteboard.general.string(forType: .string)
        defer {
            NSPasteboard.general.clearContents()
            if let saved { NSPasteboard.general.setString(saved, forType: .string) }
        }
        try await body()
    }

    @Test func clearsOwnValueAfterTimeout() async throws {
        try await withPreservedPasteboard {
            let manager = ClipboardManager()
            manager.clearAfterSeconds = 1
            manager.copySecret("example-secret-not-real")
            #expect(NSPasteboard.general.string(forType: .string) == "example-secret-not-real")
            #expect(manager.secondsRemaining == 1)
            try await Task.sleep(for: .seconds(2.5))
            #expect(NSPasteboard.general.string(forType: .string) != "example-secret-not-real")
            #expect(manager.secondsRemaining == nil)
        }
    }

    @Test func neverClearsSomeoneElsesValue() async throws {
        try await withPreservedPasteboard {
            let manager = ClipboardManager()
            manager.clearAfterSeconds = 1
            manager.copySecret("example-secret-not-real")
            // The user copies something else before the timer fires.
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString("user text", forType: .string)
            try await Task.sleep(for: .seconds(2.5))
            #expect(NSPasteboard.general.string(forType: .string) == "user text")
        }
    }

    @Test func explicitClearOnLockOnlyWhenOwned() async throws {
        try await withPreservedPasteboard {
            let manager = ClipboardManager()
            manager.clearAfterSeconds = nil // "never" — lock must still clear
            manager.copySecret("example-secret-not-real")
            manager.clearIfOwned()
            #expect(NSPasteboard.general.string(forType: .string) == nil)

            NSPasteboard.general.setString("user text", forType: .string)
            manager.clearIfOwned() // not owned anymore → untouched
            #expect(NSPasteboard.general.string(forType: .string) == "user text")
        }
    }
}

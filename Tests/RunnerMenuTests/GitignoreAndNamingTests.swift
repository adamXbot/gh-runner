import Foundation
import Testing
@testable import RunnerMenu

struct GitignoreAndNamingTests {
    @Test @MainActor func gitignoreEntryIsAddedAndDeduplicated() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("RM-gi-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        RunnerStore.addGitignoreEntry(folder: "actions-runner-foo", inParent: dir)
        RunnerStore.addGitignoreEntry(folder: "actions-runner-foo", inParent: dir)  // duplicate → no-op

        let contents = try String(contentsOf: dir.appendingPathComponent(".gitignore"), encoding: .utf8)
        let occurrences = contents.components(separatedBy: "actions-runner-foo/").count - 1
        #expect(occurrences == 1)
    }

    @Test @MainActor func gitignoreAppendsToExistingFile() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("RM-gi2-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let gitignore = dir.appendingPathComponent(".gitignore")
        try "node_modules/\n".write(to: gitignore, atomically: true, encoding: .utf8)

        RunnerStore.addGitignoreEntry(folder: "actions-runner-bar", inParent: dir)

        let contents = try String(contentsOf: gitignore, encoding: .utf8)
        #expect(contents.contains("node_modules/"))
        #expect(contents.contains("actions-runner-bar/"))
    }

    @Test func folderNameSanitizerReplacesInvalidCharacters() {
        #expect(RegisterRunnerView.sanitize("Hello World") == "Hello-World")
        #expect(RegisterRunnerView.sanitize("my.repo_name-1") == "my.repo_name-1")
        #expect(RegisterRunnerView.sanitize("a/b") == "a-b")
    }

    @Test func folderNameValidatorRejectsUnsafeNames() {
        #expect(RegisterRunnerView.isValidFolderName("actions-runner-foo"))
        #expect(RegisterRunnerView.isValidFolderName("my.runner_1"))
        #expect(!RegisterRunnerView.isValidFolderName(""))
        #expect(!RegisterRunnerView.isValidFolderName("   "))
        #expect(!RegisterRunnerView.isValidFolderName("."))
        #expect(!RegisterRunnerView.isValidFolderName(".."))
        #expect(!RegisterRunnerView.isValidFolderName("foo/bar"))
        #expect(!RegisterRunnerView.isValidFolderName("../shared"))
    }

    @Test func folderNameDedupeAppendsNumericSuffix() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("RM-dedupe-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        let base = "actions-runner-foo"
        #expect(RegisterRunnerView.uniqueFolderName(base: base, in: dir) == base)

        try FileManager.default.createDirectory(at: dir.appendingPathComponent(base), withIntermediateDirectories: true)
        #expect(RegisterRunnerView.uniqueFolderName(base: base, in: dir) == "\(base)-2")

        try FileManager.default.createDirectory(at: dir.appendingPathComponent("\(base)-2"), withIntermediateDirectories: true)
        #expect(RegisterRunnerView.uniqueFolderName(base: base, in: dir) == "\(base)-3")

        #expect(RegisterRunnerView.uniqueFolderName(base: base, in: nil) == base)
    }
}

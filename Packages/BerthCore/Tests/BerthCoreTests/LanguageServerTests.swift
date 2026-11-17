import Foundation
import Testing
@testable import BerthCore

struct LanguageServerFramingTests {
    func frame(_ body: String) -> Data {
        Data("Content-Length: \(Data(body.utf8).count)\r\n\r\n\(body)".utf8)
    }

    @Test func headerSplitAcrossChunks() {
        let message = frame(#"{"id":1}"#)
        var framing = LanguageServerFraming()

        #expect(framing.append(message.prefix(9)).isEmpty)
        #expect(framing.append(message.dropFirst(9).prefix(10)).isEmpty)
        #expect(framing.append(message.dropFirst(19)) == [Data(#"{"id":1}"#.utf8)])
    }

    @Test func twoMessagesInOneChunkAndATrailingPartial() {
        let third = frame(#"{"id":3}"#)
        var framing = LanguageServerFraming()

        #expect(framing.append(frame(#"{"id":1}"#) + frame(#"{"id":2}"#) + third.prefix(25)) == [Data(#"{"id":1}"#.utf8), Data(#"{"id":2}"#.utf8)])
        #expect(framing.append(third.dropFirst(25)) == [Data(#"{"id":3}"#.utf8)])
    }

    @Test func lengthCountsBytesOfAMultibyteBodySplitMidCharacter() {
        let body = #"{"message":"Tröjan 🚢 är här"}"#
        let message = frame(body)
        let split = message.count - 10
        var framing = LanguageServerFraming()

        #expect(framing.append(message.prefix(split)).isEmpty)
        #expect(framing.append(message.dropFirst(split)) == [Data(body.utf8)])
    }

    @Test func headerNamesAreCaseInsensitiveAndOtherHeadersAreIgnored() {
        var framing = LanguageServerFraming()
        let message = Data("content-type: application/vscode-jsonrpc; charset=utf-8\r\ncontent-length: 2\r\n\r\n{}".utf8)

        #expect(framing.append(message) == [Data("{}".utf8)])
    }
}

final class LanguageServersTests {
    let root = FileManager.default.temporaryDirectory.appending(path: "berth-lsp-\(UUID().uuidString)").resolvingSymlinksInPath()

    deinit {
        try? FileManager.default.removeItem(at: root)
    }

    @discardableResult
    func executable(_ path: String) throws -> String {
        let url = root.appending(path: path)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try "#!/bin/sh\n".write(to: url, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
        return url.path
    }

    @Test func languageIDs() {
        #expect(LanguageServers.languageID(forFile: "Sources/App.swift") == "swift")
        #expect(LanguageServers.languageID(forFile: "src/main.rs") == "rust")
        #expect(LanguageServers.languageID(forFile: "web/View.TSX") == "typescriptreact")
        #expect(LanguageServers.languageID(forFile: "index.mjs") == "javascript")
        #expect(LanguageServers.languageID(forFile: "README.md") == nil)
    }

    @Test func resolvesServersFromPathHomeAndRepository() throws {
        let home = root.appending(path: "home").path
        let bin = root.appending(path: "bin").path
        let repo = root.appending(path: "repo").path
        let environment = ["HOME": home, "PATH": "\(bin):/nonexistent"]

        let sourceKit = try executable("bin/sourcekit-lsp")
        let rustup = try executable("home/.cargo/bin/rustup")
        try FileManager.default.linkItem(atPath: rustup, toPath: "\(home)/.cargo/bin/rust-analyzer")
        let rustAnalyzer = try executable("home/.rustup/toolchains/stable-aarch64-apple-darwin/bin/rust-analyzer")
        let server = try executable("repo/node_modules/.bin/typescript-language-server")
        try executable("home/.nvm/versions/node/v22.9.0/bin/node")
        let node = try executable("home/.nvm/versions/node/v22.21.1/bin/node")
        try executable("home/.nvm/versions/node/v9.11.2/bin/node")

        #expect(LanguageServers.command(forLanguage: "swift", root: repo, environment: environment) == LanguageServerCommand(executable: sourceKit, arguments: []))
        #expect(LanguageServers.command(forLanguage: "rust", root: repo, environment: environment) == LanguageServerCommand(executable: rustAnalyzer, arguments: []))
        #expect(LanguageServers.command(forLanguage: "typescriptreact", root: repo, environment: environment) == LanguageServerCommand(executable: node, arguments: [server, "--stdio"]))
        #expect(LanguageServers.command(forLanguage: "python", root: repo, environment: environment) == nil)
    }
}

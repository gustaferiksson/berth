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
    func executable(_ path: String, contents: String = "#!/bin/sh\n") throws -> String {
        let url = root.appending(path: path)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try contents.write(to: url, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
        return url.path
    }

    @Test func languageIDs() {
        #expect(LanguageServers.languageID(forFile: "Sources/App.swift") == "swift")
        #expect(LanguageServers.languageID(forFile: "src/main.rs") == "rust")
        #expect(LanguageServers.languageID(forFile: "web/View.TSX") == "typescriptreact")
        #expect(LanguageServers.languageID(forFile: "index.mjs") == "javascript")
        #expect(LanguageServers.languageID(forFile: "README.md") == "md")
    }

    @Test func serversMatchFilesByExtensionOrLanguageID() {
        let biome = LanguageServerEntry(name: "Biome", command: "biome", languages: ["ts", "json"])
        let typeScript = LanguageServerEntry.defaults[2]

        #expect(biome.serves("src/index.ts"))
        #expect(biome.serves("biome.json"))
        #expect(!biome.serves("src/View.tsx"))
        #expect(typeScript.serves("src/View.TSX"))
        #expect(typeScript.serves("scripts/build.mjs"))
        #expect(!typeScript.serves("README.md"))
    }

    @Test func rootMarkersPickTheNearestFolderInsideTheRepository() throws {
        let repo = root.appending(path: "repo").path
        let oxlint = LanguageServerEntry(name: "oxlint", command: "oxlint", rootMarkers: [".oxlintrc.json"])
        let biome = LanguageServerEntry(name: "Biome", command: "biome", rootMarkers: ["biome.json", "biome.jsonc"])
        try FileManager.default.createDirectory(atPath: "\(repo)/packages/web/src", withIntermediateDirectories: true)
        try "{}".write(toFile: "\(repo)/packages/web/biome.jsonc", atomically: true, encoding: .utf8)
        try "{}".write(toFile: "\(repo)/biome.json", atomically: true, encoding: .utf8)
        try "{}".write(toFile: "\(root.path)/.oxlintrc.json", atomically: true, encoding: .utf8)

        #expect(LanguageServers.root(forFile: "packages/web/src/index.ts", server: biome, repositoryRoot: repo) == "\(repo)/packages/web")
        #expect(LanguageServers.root(forFile: "packages/api/index.ts", server: biome, repositoryRoot: repo) == repo)
        #expect(LanguageServers.root(forFile: "packages/web/src/index.ts", server: oxlint, repositoryRoot: repo) == nil)
        #expect(LanguageServers.root(forFile: "packages/web/src/index.ts", server: LanguageServerEntry.defaults[2], repositoryRoot: repo) == repo)
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
        let server = try executable("repo/node_modules/.bin/typescript-language-server", contents: "#!/usr/bin/env node\n")
        try executable("home/.nvm/versions/node/v22.9.0/bin/node")
        let node = try executable("home/.nvm/versions/node/v22.21.1/bin/node")
        try executable("home/.nvm/versions/node/v9.11.2/bin/node")

        #expect(LanguageServers.command(for: LanguageServerEntry.defaults[0], root: repo, environment: environment) == LanguageServerCommand(executable: sourceKit, arguments: []))
        #expect(LanguageServers.command(for: LanguageServerEntry.defaults[1], root: repo, environment: environment) == LanguageServerCommand(executable: rustAnalyzer, arguments: []))
        #expect(LanguageServers.command(for: LanguageServerEntry.defaults[2], root: repo, environment: environment) == LanguageServerCommand(executable: node, arguments: [server, "--stdio"]))
        #expect(LanguageServers.command(for: LanguageServerEntry(name: "Missing", command: "berth-missing-server"), root: repo, environment: environment) == nil)
    }

    @Test func repositoryBinariesComeBeforePathAndAbsoluteCommandsAreUsedAsIs() throws {
        let home = root.appending(path: "home").path
        let repo = root.appending(path: "repo").path
        let environment = ["HOME": home, "PATH": root.appending(path: "bin").path]

        try executable("bin/oxlint")
        let local = try executable("repo/node_modules/.bin/oxlint")
        let absolute = try executable("tools/eslint-server")
        let homeRelative = try executable("home/bin/biome")

        #expect(LanguageServers.command(for: LanguageServerEntry(name: "oxlint", command: "oxlint", arguments: ["--lsp"]), root: repo, environment: environment) == LanguageServerCommand(executable: local, arguments: ["--lsp"]))
        #expect(LanguageServers.command(for: LanguageServerEntry(name: "ESLint", command: absolute, arguments: ["--stdio"]), root: repo, environment: environment) == LanguageServerCommand(executable: absolute, arguments: ["--stdio"]))
        #expect(LanguageServers.command(for: LanguageServerEntry(name: "Biome", command: "~/bin/biome", arguments: ["lsp-proxy"]), root: repo, environment: environment) == LanguageServerCommand(executable: homeRelative, arguments: ["lsp-proxy"]))
    }
}

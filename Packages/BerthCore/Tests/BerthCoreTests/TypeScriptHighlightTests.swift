import Foundation
import SwiftTreeSitter
import Testing
import TreeSitterTSX
import TreeSitterTypeScript

struct TypeScriptHighlightTests {
    @Test(arguments: ["ts", "tsx"]) func declarationCaptures(fileExtension: String) throws {
        let isTSX = fileExtension == "tsx"
        let language = Language(isTSX ? tree_sitter_tsx() : tree_sitter_typescript())
        let typeScriptBundle = isTSX ? "TreeSitterTypeScript_TreeSitterTSX" : "TreeSitterTypeScript_TreeSitterTypeScript"
        let javaScriptBundle = "TreeSitterJavaScript_TreeSitterJavaScript"
        var urls = try [queryURL(in: typeScriptBundle), queryURL(in: javaScriptBundle)]
        if isTSX { try urls.append(queryURL(in: javaScriptBundle, name: "highlights-jsx")) }
        urls.append(URL(filePath: #filePath).deletingLastPathComponent().appending(path: "../../../../Resources/highlights-typescript.scm").standardizedFileURL)
        let sources = try urls.map { try Data(contentsOf: $0) }
        let query = try Query(language: language, data: Data(sources.joined(separator: Data("\n".utf8))))

        let source = """
        const isDateCell = (value: string) => value.length > 0;
        const DateCell = function () {};
        const generate = function* () {};
        const require = () => {};
        export const x = new Tool({});
        function inspect() {
            const missing = false;
            const keys = new Set();
            const UPPER_CASE = 1;
            const { label, key: alias = 0, fallback = 1, ...rest } = input;
            const [first, second = 0, ...tail] = values;
        }
        let counter = 0;
        let Task = () => {};
        let console = 0;
        var TOTAL = function () {};
        """
        let parser = Parser()
        try parser.setLanguage(language)
        let tree = try #require(parser.parse(source))
        try #require(tree.rootNode?.hasError == false)
        let matches = query.execute(in: tree).resolve(with: .init(string: source))
        let groups = Dictionary(grouping: matches) { $0.metadata["priority"] == "declaration" }
        let highlights = groups[false, default: []].highlights() + groups[true, default: []].highlights()
        let expected = [
            "isDateCell": "function", "DateCell": "function", "generate": "function", "require": "function",
            "x": "constant", "missing": "constant", "keys": "constant", "UPPER_CASE": "constant",
            "label": "constant", "alias": "constant", "fallback": "constant", "rest": "constant",
            "first": "constant", "second": "constant", "tail": "constant",
            "counter": "variable", "Task": "variable", "console": "variable", "TOTAL": "variable",
        ]
        for (identifier, capture) in expected.sorted(by: { $0.key < $1.key }) {
            let range = (source as NSString).range(of: "\\b\(identifier)\\b", options: .regularExpression)
            try #require(range.location != NSNotFound)
            #expect(highlights.last { $0.range == range }?.name == capture, "\(identifier) in \(fileExtension)")
        }
    }

    private func queryURL(in bundleName: String, name: String = "highlights") throws -> URL {
        let bundles = Bundle.module.bundleURL.deletingLastPathComponent()
        let bundle = try #require(Bundle(url: bundles.appending(path: "\(bundleName).bundle")))
        return try #require(bundle.url(forResource: name, withExtension: "scm", subdirectory: "queries"))
    }
}

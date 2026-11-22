import BerthCore
import Foundation
import Testing

struct CodexModelsTests {
    @Test func loadsListedModelsInPriorityOrder() throws {
        let fixtures = try #require(Bundle.module.url(forResource: "Fixtures", withExtension: nil))
        let models = CodexModels.load(from: fixtures.appending(path: "codex-models"))

        #expect(models.map(\.slug) == ["fixture-first", "fixture-second", "fixture-sparse"])
        #expect(models.map(\.displayName) == ["Fixture First", "Fixture Second", "fixture-sparse"])
        #expect(models.map(\.defaultEffort) == ["medium", "low", nil])
        #expect(models.map(\.efforts) == [["medium", "high"], ["low"], []])
    }
}

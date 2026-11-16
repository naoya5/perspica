import Testing
@testable import YakuCore

@Suite struct LlamaServerVersionTests {
    @Test func readsANumberedRelease() {
        let output = """
            version: 0.7.0 (build 11669, commit 620d2225c)
            built with AppleClang 21.0.0.21000334 for Darwin arm64
            """
        #expect(LlamaServerVersion.parse(output) == LlamaServerVersion(release: [0, 7, 0], build: 11669))
    }

    @Test func readsABuildFromBeforeNumberedReleases() {
        #expect(LlamaServerVersion.parse("version: 6123 (abc1234)\n") == LlamaServerVersion(release: nil, build: 6123))
    }

    @Test func aSourceBuildKeepsItsReleaseNumber() {
        // A shallow checkout of the v1.0.0 tag, built with CMake.
        let version = LlamaServerVersion.parse("version: 1.0.0-dev (build 1, commit b1b770d)")
        #expect(version == LlamaServerVersion(release: [1, 0, 0], build: 1))
        #expect(version?.isSupported() == true)
    }

    @Test func noVersionLineIsNil() {
        #expect(LlamaServerVersion.parse("error: unknown argument: --version") == nil)
        #expect(LlamaServerVersion.parse("") == nil)
    }

    @Test func theTestedReleaseAndNewerOnesAreSupported() {
        #expect(LlamaServerVersion(release: [0, 7, 0], build: 11669).isSupported())
        #expect(LlamaServerVersion(release: [1, 0, 0], build: 12400).isSupported())
        #expect(LlamaServerVersion(release: [0, 10], build: nil).isSupported())
    }

    @Test func olderReleasesAndOldBuildsAreRefused() {
        #expect(!LlamaServerVersion(release: [0, 6, 9], build: 11500).isSupported())
        #expect(!LlamaServerVersion(release: nil, build: 6123).isSupported())
    }

    @Test func describesItselfForMessagesAndLogs() {
        #expect(LlamaServerVersion(release: [1, 0, 0], build: 1).description == "1.0.0")
        #expect(LlamaServerVersion(release: nil, build: 6123).description == "build 6123")
    }
}

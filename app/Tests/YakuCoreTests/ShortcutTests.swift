import Foundation
import Testing
@testable import YakuCore

@Suite("Shortcuts")
struct ShortcutTests {
    @Test("the display string uses the Apple order")
    func display() {
        let shortcut = Shortcut(keyCode: 38, modifiers: [.control, .option]) // J
        #expect(shortcut.display == "⌃⌥J")

        let everything = Shortcut(keyCode: 0, modifiers: [.command, .option, .control, .shift])
        #expect(everything.display == "⌃⌥⇧⌘A")

        #expect(Shortcut(keyCode: 49, modifiers: [.command]).display == "⌘Space")
        #expect(Shortcut(keyCode: 36, modifiers: [.command]).display == "⌘↩")
        #expect(Shortcut(keyCode: 123, modifiers: [.command]).display == "⌘←")
    }

    @Test("an unknown key code still has a name")
    func unknownKey() {
        #expect(Shortcut(keyCode: 200, modifiers: [.command]).display == "⌘Key200")
    }

    @Test("a shortcut needs at least one modifier to be usable")
    func usable() {
        #expect(Shortcut(keyCode: 38, modifiers: [.control]).isUsable)
        #expect(!Shortcut(keyCode: 38, modifiers: []).isUsable)
    }

    @Test("no conflicts when everything is different")
    func noConflicts() {
        let bindings = [
            ShortcutBinding(id: "a", shortcut: Shortcut(keyCode: 38, modifiers: [.control, .option])),
            ShortcutBinding(id: "b", shortcut: Shortcut(keyCode: 40, modifiers: [.control, .option])),
            ShortcutBinding(id: "c", shortcut: Shortcut(keyCode: 31, modifiers: [.control, .option])),
        ]
        #expect(ShortcutConflict.pairs(bindings).isEmpty)
        #expect(ShortcutConflict.conflictingIDs(bindings).isEmpty)
    }

    @Test("the same key with different modifiers is not a conflict")
    func differentModifiers() {
        let bindings = [
            ShortcutBinding(id: "a", shortcut: Shortcut(keyCode: 38, modifiers: [.control, .option])),
            ShortcutBinding(id: "b", shortcut: Shortcut(keyCode: 38, modifiers: [.control, .option, .shift])),
            ShortcutBinding(id: "c", shortcut: Shortcut(keyCode: 38, modifiers: [.command])),
        ]
        #expect(ShortcutConflict.pairs(bindings).isEmpty)
    }

    @Test("two identical shortcuts are reported with both ids")
    func conflict() {
        let shared = Shortcut(keyCode: 38, modifiers: [.control, .option])
        let bindings = [
            ShortcutBinding(id: "a", shortcut: shared),
            ShortcutBinding(id: "b", shortcut: shared),
            ShortcutBinding(id: "c", shortcut: Shortcut(keyCode: 40, modifiers: [.command])),
        ]
        #expect(ShortcutConflict.pairs(bindings).count == 1)
        #expect(ShortcutConflict.conflictingIDs(bindings) == ["a", "b"])
    }

    @Test("three identical shortcuts produce three pairs")
    func threeWay() {
        let shared = Shortcut(keyCode: 38, modifiers: [.command])
        let bindings = [
            ShortcutBinding(id: "a", shortcut: shared),
            ShortcutBinding(id: "b", shortcut: shared),
            ShortcutBinding(id: "c", shortcut: shared),
        ]
        #expect(ShortcutConflict.pairs(bindings).count == 3)
        #expect(ShortcutConflict.conflictingIDs(bindings) == ["a", "b", "c"])
    }

    @Test("a cleared or modifier-less shortcut never conflicts")
    func cleared() {
        let bindings = [
            ShortcutBinding(id: "a", shortcut: nil),
            ShortcutBinding(id: "b", shortcut: nil),
            ShortcutBinding(id: "c", shortcut: Shortcut(keyCode: 38, modifiers: [])),
        ]
        #expect(ShortcutConflict.pairs(bindings).isEmpty)
    }

    @Test("the codec round trips")
    func codec() {
        let shortcut = Shortcut(keyCode: 38, modifiers: [.control, .option])
        let encoded = ShortcutCodec.encode(shortcut)
        #expect(encoded == "38:6")
        #expect(ShortcutCodec.decode(encoded) == shortcut)
        #expect(ShortcutCodec.decode("nonsense") == nil)
    }
}

@Suite("Model catalogue")
struct ModelCatalogTests {
    @Test("the three sizes are present in order")
    func sizes() {
        #expect(ModelCatalog.models.map(\.id) == ["0.8b", "2b", "8b"])
    }

    @Test("every entry is a Q4_K_M GGUF in its own repository")
    func files() {
        for model in ModelCatalog.models {
            #expect(model.fileName.hasSuffix("-Q4_K_M.gguf"))
            #expect(model.repository.hasSuffix("-GGUF"))
            #expect(model.repository.contains(model.id))
            #expect(model.sha256.count == 64)
            #expect(model.bytes > 0)
        }
    }

    @Test("the 0.8B numbers match what Hugging Face reports")
    func zeroEight() {
        let model = ModelCatalog.models[0]
        #expect(model.repository == "pfnet/plamo-3-translate-0.8b-GGUF")
        #expect(model.fileName == "plamo-3-translate-0.8b-Q4_K_M.gguf")
        #expect(model.bytes == 573_123_200)
        #expect(model.sha256 == "923b2f28a9856de1b8b3b610a7e59ded0b14d007466fd5dd526e6a9ecaadafdd")
        #expect(model.sizeInGigabytes == "0.57 GB")
        #expect(model.shortName == "PLaMo 0.8B")
    }

    @Test("the download URL points at Hugging Face")
    func url() {
        let model = ModelCatalog.models[1]
        #expect(model.downloadURL.absoluteString
            == "https://huggingface.co/pfnet/plamo-3-translate-2b-GGUF/resolve/main/plamo-3-translate-2b-Q4_K_M.gguf")
    }

    @Test("lookup by id, and the default is 0.8B")
    func lookup() {
        #expect(ModelCatalog.model(id: "8b")?.id == "8b")
        #expect(ModelCatalog.model(id: "31b") == nil)
        #expect(ModelCatalog.model(id: nil) == nil)
        #expect(ModelCatalog.defaultModelID == "0.8b")
    }

    @Test("the memory estimate is the file plus the working set")
    func memory() {
        for model in ModelCatalog.models {
            #expect(model.memoryEstimateBytes == model.bytes + 540_000_000)
        }
        #expect(ModelCatalog.models[0].memoryHint == "約 1.1 GB")
    }
}

@Suite("Byte counts")
struct ByteCountTests {
    @Test("sizes are formatted in the model card's units")
    func formatting() {
        #expect(ByteCount.format(573_123_200) == "0.57 GB")
        #expect(ByteCount.format(1_807_199_392) == "1.81 GB")
        #expect(ByteCount.format(5_280_442_080) == "5.28 GB")
        #expect(ByteCount.format(2_000_000) == "2 MB")
        #expect(ByteCount.format(4_500) == "4 KB")
        #expect(ByteCount.format(999_999) == "1000 KB")
        #expect(ByteCount.format(99_999_999) == "100 MB")
        #expect(ByteCount.format(0) == "0 KB")
    }
}

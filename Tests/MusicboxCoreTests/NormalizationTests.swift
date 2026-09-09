import Testing
@testable import MusicboxCore

@Suite("Normalization")
struct NormalizationTests {

    @Test("lowercases and strips diacritics")
    func diacriticStrip() {
        #expect(Normalization.normalize("Björk") == "bjork")
        #expect(Normalization.normalize("Sigur Rós") == "sigur ros")
        #expect(Normalization.normalize("Café") == "cafe")
        #expect(Normalization.normalize("MÖTLEY CRÜE") == "motley crue")
    }

    @Test("folds non-decomposing special characters")
    func specialFolds() {
        #expect(Normalization.normalize("straße") == "strasse")
        #expect(Normalization.normalize("Ærø") == "aero")
        #expect(Normalization.normalize("Łódź") == "lodz")
        #expect(Normalization.normalize("Đorđe") == "dorde")
        #expect(Normalization.normalize("Þór") == "thor")
        #expect(Normalization.normalize("Eðvarð") == "edvard")
    }

    @Test("collapses whitespace runs and trims")
    func whitespaceCollapse() {
        #expect(Normalization.normalize("  Too   Many   Spaces  ") == "too many spaces")
        #expect(Normalization.normalize("Tab\tSeparated\nWords") == "tab separated words")
    }

    @Test("tight strips punctuation so contractions match")
    func tightStripsPunctuation() {
        #expect(Normalization.tight("Don't") == "dont")
        #expect(Normalization.tight("Don't") == Normalization.tight("dont"))
        #expect(Normalization.normalize("Don't") == "don't")
        #expect(Normalization.tight("Rock 'n' Roll!") == "rocknroll")
    }

    @Test("normalize is idempotent")
    func idempotent() {
        let once = Normalization.normalize("Café Tacvba")
        let twice = Normalization.normalize(once)
        #expect(once == twice)
    }
}

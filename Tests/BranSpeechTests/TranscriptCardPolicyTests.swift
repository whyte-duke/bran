import BranSpeech
import Testing

@Suite("Mise en page des cartes de dictée")
struct TranscriptCardPolicyTests {

    @Test("Une longue dictée repliée reste bornée et non sélectionnable")
    func collapsedPreviewCannotEscapeItsCard() {
        let policy = TranscriptCardPolicy(isExpanded: false)

        #expect(policy.lineLimit == 3)
        #expect(policy.allowsSelection == false)
        #expect(policy.fixesVerticalSize == false)
    }

    @Test("Une dictée ouverte montre et sélectionne tout son texte")
    func expandedTranscriptRemainsReadable() {
        let policy = TranscriptCardPolicy(isExpanded: true)

        #expect(policy.lineLimit == nil)
        #expect(policy.allowsSelection)
        #expect(policy.fixesVerticalSize)
    }
}

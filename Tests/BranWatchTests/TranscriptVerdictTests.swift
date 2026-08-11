import Foundation
import Testing
@testable import BranWatch

@Suite("Lecture des transcriptions")
struct TranscriptVerdictTests {

    /// Les lignes réelles sont énormes. Celles-ci ne gardent que ce que le
    /// lecteur regarde — c'est aussi une façon de vérifier qu'il ne regarde
    /// rien d'autre.
    private func assistant(stop: String, cwd: String = "/p/crm", branch: String = "main") -> String {
        """
        {"type":"assistant","cwd":"\(cwd)","gitBranch":"\(branch)","sessionId":"s1",\
        "timestamp":"2026-08-05T15:58:01.566Z","message":{"stop_reason":"\(stop)"}}
        """
    }

    @Test("Le dernier tour terminé veut dire : elle vous attend")
    func dernierTourTermine() {
        let reading = TranscriptVerdict.read(
            lines: [assistant(stop: "tool_use"), assistant(stop: "end_turn")],
            tailIsTruncated: false
        )

        #expect(reading.state == .waiting)
        #expect(reading.workingDirectory == "/p/crm")
        #expect(reading.branch == "main")
        #expect(reading.sessionID == "s1")
        #expect(reading.endedAt == "2026-08-05T15:58:01.566Z")
    }

    /// Le cœur du sujet. Mesuré sur une session réelle : 93 `tool_use` pour
    /// 2 `end_turn`. Un capteur fondé sur la date du fichier dirait « elle vient
    /// d'écrire, donc il se passe quelque chose » dans les deux cas et ne
    /// trancherait rien. L'ordre des enregistrements, lui, tranche.
    @Test("Un appel d'outil après le dernier tour veut dire : elle travaille")
    func appelDOutilApresLeTour() {
        let reading = TranscriptVerdict.read(
            lines: [assistant(stop: "end_turn"), assistant(stop: "tool_use")],
            tailIsTruncated: false
        )

        #expect(reading.state == .working)
        #expect(reading.endedAt == nil)
    }

    @Test("Sans le moindre enregistrement assistant, on dit qu'on ne sait pas")
    func aucunEnregistrementAssistant() {
        let reading = TranscriptVerdict.read(
            lines: ["{\"type\":\"user\",\"cwd\":\"/p\"}"],
            tailIsTruncated: false
        )

        #expect(reading.state == .unknown)
    }

    /// CR-6 : le fichier est écrit en continu par une session vivante, donc la
    /// dernière ligne peut être coupée en plein milieu.
    @Test("Une dernière ligne tronquée est ignorée, pas fatale")
    func derniereLigneTronquee() {
        let coupee = "{\"type\":\"assistant\",\"message\":{\"stop_re"
        let reading = TranscriptVerdict.read(
            lines: [assistant(stop: "end_turn"), coupee],
            tailIsTruncated: false
        )

        #expect(reading.state == .waiting)
    }

    /// On ne lit que la fin du fichier pour borner le coût — le plus gros du
    /// dossier pèse 20 Mo. Le premier fragment est donc coupé.
    @Test("Le premier fragment d'une lecture partielle est jeté")
    func premierFragmentJete() {
        let fragment = "_reason\":\"end_turn\"},\"type\":\"assistant\"}"
        let reading = TranscriptVerdict.read(
            lines: [fragment, assistant(stop: "tool_use")],
            tailIsTruncated: true
        )

        #expect(reading.state == .working)
    }

    @Test("L'identité est cherchée sur toutes les lignes, pas seulement la dernière")
    func identiteSurNImporteQuelleLigne() {
        let sansIdentite = "{\"type\":\"assistant\",\"message\":{\"stop_reason\":\"end_turn\"}}"
        let reading = TranscriptVerdict.read(
            lines: [assistant(stop: "tool_use", cwd: "/p/bran", branch: "feat/x"), sansIdentite],
            tailIsTruncated: false
        )

        #expect(reading.state == .waiting)
        #expect(reading.workingDirectory == "/p/bran")
        #expect(reading.branch == "feat/x")
    }

    // MARK: - Le contenu des messages ne doit jamais être pris pour la structure

    /// Le cas se produit dans ce dépôt précisément : on y écrit *sur* le format
    /// des transcriptions, donc les transcriptions contiennent littéralement les
    /// marqueurs qu'on cherche. Une recherche de sous-chaîne naïve lisait
    /// « tour terminé » dans un message qui ne faisait que citer le marqueur.
    @Test("Un message qui CITE le marqueur de fin de tour ne le déclenche pas")
    func citationNestPasStructure() {
        let citation = """
        {"type":"assistant","cwd":"/p","gitBranch":"main","sessionId":"s1",\
        "timestamp":"t","message":{"stop_reason":"tool_use",\
        "content":[{"type":"text","text":"le marqueur s'écrit \\"stop_reason\\":\\"end_turn\\" "}]}}
        """

        let reading = TranscriptVerdict.read(lines: [citation], tailIsTruncated: false)
        #expect(reading.state == .working, "c'est le vrai stop_reason qui compte, pas la citation")
    }

    @Test("Un message utilisateur qui cite le type assistant n'est pas un enregistrement assistant")
    func citationDuTypeNestPasUnType() {
        let ligne = """
        {"type":"user","cwd":"/p","message":{"content":"regarde \\"type\\":\\"assistant\\" ici"}}
        """

        #expect(TranscriptVerdict.read(lines: [ligne], tailIsTruncated: false).state == .unknown)
    }

    @Test("Une clé de même nom imbriquée ne remplace pas celle du premier niveau")
    func cleImbriqueeNeGagnePas() {
        let ligne = """
        {"type":"assistant","cwd":"/vrai","message":{"stop_reason":"end_turn",\
        "meta":{"cwd":"/faux"}},"gitBranch":"main"}
        """

        let reading = TranscriptVerdict.read(lines: [ligne], tailIsTruncated: false)
        #expect(reading.workingDirectory == "/vrai")
    }

    // MARK: - La porte de vivacité

    /// Pris en défaut au premier essai sur un vrai fichier : dernier tour
    /// terminé, fichier touché quatorze minutes plus tôt, et **aucun processus
    /// vivant**. Sans cette porte, la toute première alerte du produit aurait
    /// été un fantôme.
    @Test("Une session dont le processus est mort n'attend personne")
    func processusMortNAttendPas() {
        let brute = TranscriptVerdict.read(
            lines: [assistant(stop: "end_turn", cwd: "/p/mort")],
            tailIsTruncated: false
        )
        #expect(brute.state == .waiting)

        let filtree = TranscriptVerdict.gated(brute, liveWorkingDirectories: ["/p/vivant"])
        #expect(filtree.state == .stale)
        #expect(filtree.workingDirectory == "/p/mort", "la voie reste visible, elle ne disparaît pas")
    }

    @Test("Une session dont le processus tourne attend bien")
    func processusVivantAttend() {
        let brute = TranscriptVerdict.read(
            lines: [assistant(stop: "end_turn", cwd: "/p/vivant")],
            tailIsTruncated: false
        )
        let filtree = TranscriptVerdict.gated(brute, liveWorkingDirectories: ["/p/vivant"])

        #expect(filtree.state == .waiting)
    }

    @Test("La porte ne touche pas aux états qui ne sont pas une attente")
    func porteNeTouchePasAuReste() {
        let travaille = TranscriptVerdict.read(
            lines: [assistant(stop: "tool_use", cwd: "/p/mort")],
            tailIsTruncated: false
        )
        #expect(TranscriptVerdict.gated(travaille, liveWorkingDirectories: []).state == .working)
    }

    /// CR-3. Ce test est la garantie qu'on n'exfiltre rien : même si la ligne
    /// contient une clé d'API, aucun champ du type de retour ne peut la porter.
    @Test("Aucun contenu de message ne peut ressortir du lecteur")
    func aucunContenuNeRessort() {
        let secret = "sk-ant-CECI-EST-UN-SECRET"
        let ligne = """
        {"type":"assistant","cwd":"/p","gitBranch":"main","sessionId":"s1",\
        "timestamp":"t","message":{"stop_reason":"end_turn",\
        "content":[{"type":"text","text":"ma clé est \(secret)"}]}}
        """

        let reading = TranscriptVerdict.read(lines: [ligne], tailIsTruncated: false)
        let ressorti = [
            reading.sessionID, reading.workingDirectory, reading.branch, reading.endedAt,
        ].compactMap { $0 }.joined()

        #expect(reading.state == .waiting)
        #expect(ressorti.contains(secret) == false)
    }

    // MARK: - La queue brute

    /// **Le défaut que ces trois tests ferment.** La lecture décodait les
    /// 256 derniers Kio d'un bloc, avec `String(data:encoding:.utf8)`, puis
    /// découpait la chaîne obtenue. Or cette fonction rend `nil` — pas une
    /// chaîne partielle, `nil` — dès que le premier octet lu tombe au milieu
    /// d'un caractère multi-octets. La transcription entière était alors
    /// ignorée, sans un mot dans le journal, et la voie disparaissait de la
    /// liste. Le déclencheur : qu'un accent se trouve à cheval sur la coupure,
    /// c'est-à-dire une fois sur quelques-unes, sans rien de reproductible.
    ///
    /// Le découpage se fait maintenant sur les octets, et chaque ligne est
    /// décodée seule.

    @Test("Une queue coupée au milieu d'un accent ne fait pas perdre le fichier")
    func queueCoupeeAuMilieuDunCaractere() {
        var bytes = Data()
        // Les deux octets de « é », amputés du premier : ce qui reste ne peut
        // pas être décodé, et c'est exactement ce qu'une coupure à 256 Kio
        // produit.
        bytes.append(contentsOf: Array("é".utf8).dropFirst())
        bytes.append(contentsOf: Array("gment de ligne\n".utf8))
        bytes.append(contentsOf: Array(assistant(stop: "end_turn").utf8))

        let reading = TranscriptVerdict.read(utf8Tail: bytes, tailIsTruncated: true)

        #expect(reading.state == .waiting)
        #expect(reading.workingDirectory == "/p/crm")
    }

    @Test("Le découpage par octets rend les mêmes lignes que par caractères")
    func decoupageIdentique() {
        let text = assistant(stop: "tool_use") + "\n" + assistant(stop: "end_turn")
        let parCaracteres = text.split(separator: "\n", omittingEmptySubsequences: true)
            .map(String.init)
        let parOctets = TranscriptVerdict.read(utf8Tail: Data(text.utf8), tailIsTruncated: false)

        #expect(parCaracteres.count == 2)
        #expect(parOctets == TranscriptVerdict.read(lines: parCaracteres, tailIsTruncated: false))
    }

    @Test("Les lignes vides ne comptent pas, et un contenu accentué survit")
    func lignesVidesEtAccents() {
        let text = "\n\n" + assistant(stop: "end_turn", cwd: "/p/été") + "\n\n"

        let reading = TranscriptVerdict.read(utf8Tail: Data(text.utf8), tailIsTruncated: false)

        #expect(reading.state == .waiting)
        #expect(reading.workingDirectory == "/p/été")
    }
}

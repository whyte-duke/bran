import Foundation
import Testing
@testable import BranCore

/// **Ce que ce fichier protège** : que l'audio d'une réunion et le jeton du
/// Trousseau ne partent jamais vers un hôte que personne n'a approuvé.
///
/// Chaque test rejoue une entrée hostile précise, pas une famille abstraite :
/// l'URL de dépôt en clair vers une adresse du réseau local, l'URL HTTPS d'un
/// tiers, la redirection qui déplace la destination après coup, l'hôte qui
/// ressemble au bon domaine sans en être (`evilcastral.fr`), et l'adresse du
/// CRM réécrite dans les préférences par un processus qui, lui, ne peut pas
/// lire le Trousseau.
///
/// Le dernier test dit l'autre moitié : les adresses réelles de la production
/// doivent passer. Une liste d'origines trop serrée n'est pas prudente, elle
/// est en panne.
@Suite("CRMOriginPolicy")
struct CRMOriginPolicyTests {

    private let crmHost = "crm.castral.fr"

    // MARK: - L'adresse de dépôt

    @Test("Un dépôt en clair vers une adresse du réseau local est refusé")
    func depotEnClairRefuse() {
        let verdict = CRMOriginPolicy.uploadDestination("http://100.64.3.7/upload", crmHost: crmHost)
        #expect(verdict.refusal == .notHTTPS(scheme: "http"))
    }

    @Test("Un dépôt HTTPS chez un tiers est refusé, quelle que soit sa mise en forme")
    func depotChezUnTiersRefuse() {
        let verdict = CRMOriginPolicy.uploadDestination(
            "https://collecte.example/storage/v1/object/upload/sign/audio",
            crmHost: crmHost
        )
        #expect(verdict.refusal == .unapprovedHost("collecte.example"))
    }

    @Test("Le stockage Supabase du projet est accepté, jeton de signature compris")
    func stockageSupabaseAccepte() {
        let adresse = "https://nifvrjlcurdqzdwvwfxh.supabase.co/storage/v1/object/upload/sign/"
            + "recordings/Closing_2026-08-04_orpheo.mp3?token=eyJhbGciOi"
        #expect(CRMOriginPolicy.uploadDestination(adresse, crmHost: crmHost).url != nil)
    }

    @Test("Le CRM lui-même peut recevoir les octets s'il choisit de les relayer")
    func leCRMPeutRecevoirLesOctets() {
        #expect(
            CRMOriginPolicy.uploadDestination("https://crm.castral.fr/api/depot", crmHost: crmHost).url != nil
        )
    }

    /// Le piège du suffixe : `hasSuffix("supabase.co")` seul aurait accepté
    /// `notsupabase.co`, qui n'a rien à voir.
    @Test("Un hôte qui imite le domaine du stockage sans en être est refusé")
    func imitationDeDomaineRefusee() {
        #expect(
            CRMOriginPolicy.uploadDestination("https://notsupabase.co/upload", crmHost: crmHost).refusal
                == .unapprovedHost("notsupabase.co")
        )
    }

    @Test("Un identifiant glissé dans l'adresse la fait refuser")
    func identifiantDansLAdresse() {
        #expect(
            CRMOriginPolicy.uploadDestination(
                "https://voleur@nifvrjlcurdqzdwvwfxh.supabase.co/upload",
                crmHost: crmHost
            ).refusal == .credentialsInURL
        )
    }

    // MARK: - Les redirections

    @Test("Une redirection qui change d'hôte n'est pas suivie")
    func redirectionHorsOrigineRefusee() {
        #expect(
            CRMOriginPolicy.allowsRedirection(
                from: URL(string: "https://nifvrjlcurdqzdwvwfxh.supabase.co/upload")!,
                to: URL(string: "https://collecte.example/upload")!
            ) == false
        )
    }

    @Test("Une redirection qui reste sur le même hôte est suivie")
    func redirectionInterneAcceptee() {
        #expect(
            CRMOriginPolicy.allowsRedirection(
                from: URL(string: "https://nifvrjlcurdqzdwvwfxh.supabase.co/upload")!,
                to: URL(string: "https://nifvrjlcurdqzdwvwfxh.supabase.co/storage/v1/upload")!
            )
        )
    }

    @Test("Une redirection qui retombe en clair n'est pas suivie non plus")
    func redirectionVersDuClairRefusee() {
        #expect(
            CRMOriginPolicy.allowsRedirection(
                from: URL(string: "https://nifvrjlcurdqzdwvwfxh.supabase.co/upload")!,
                to: URL(string: "http://nifvrjlcurdqzdwvwfxh.supabase.co/upload")!
            ) == false
        )
    }

    // MARK: - L'adresse du CRM

    @Test("L'adresse du CRM en production est acceptée, avec ou sans barre finale")
    func adresseDeProductionAcceptee() {
        #expect(CRMOriginPolicy.crmBase("https://crm.castral.fr").url?.absoluteString == "https://crm.castral.fr")
        #expect(CRMOriginPolicy.crmBase("  https://crm.castral.fr/  ").url?.absoluteString == "https://crm.castral.fr")
    }

    @Test("Un sous-domaine de recette reste joignable sans republier bran")
    func sousDomaineDeRecetteAccepte() {
        #expect(CRMOriginPolicy.crmBase("https://crm-recette.castral.fr").url != nil)
    }

    @Test("Une adresse de CRM réécrite vers un collecteur est refusée")
    func adresseDetourneeRefusee() {
        #expect(
            CRMOriginPolicy.crmBase("https://collecteur.example").refusal
                == .unapprovedHost("collecteur.example")
        )
    }

    @Test("Un hôte qui imite castral.fr sans en être est refusé")
    func imitationDuDomaineCRMRefusee() {
        #expect(
            CRMOriginPolicy.crmBase("https://evilcastral.fr").refusal == .unapprovedHost("evilcastral.fr")
        )
    }

    @Test("Le CRM en clair est refusé : le jeton partirait lisible sur le réseau")
    func crmEnClairRefuse() {
        #expect(CRMOriginPolicy.crmBase("http://crm.castral.fr").refusal == .notHTTPS(scheme: "http"))
    }

    @Test("Une adresse sans hôte est refusée plutôt qu'interprétée")
    func adresseSansHote() {
        #expect(CRMOriginPolicy.crmBase("crm.castral.fr").refusal == .unreadable)
        #expect(CRMOriginPolicy.crmBase("").refusal == .unreadable)
    }

    @Test("Chaque refus porte une phrase qui dit quoi corriger")
    func chaqueRefusSeLit() {
        let refus: [CRMOriginPolicy.Refusal] = [
            .unreadable, .notHTTPS(scheme: "http"), .credentialsInURL,
            .fragmentInURL, .unapprovedHost("collecte.example"),
        ]
        for refusal in refus {
            #expect(refusal.message.isEmpty == false)
            #expect(refusal.message.hasSuffix("."), "« \(refusal.message) » doit être une phrase")
        }
    }
}

/// **Ce que ce fichier protège** : que l'audio d'un client ne parte pas chez
/// quelqu'un d'autre parce qu'il partage un hébergeur avec nous.
///
/// La règle portait sur le **domaine** `supabase.co`, au motif qu'une
/// migration de projet y resterait. C'est vrai, et ça ne suffit pas :
/// `supabase.co` est mutualisé. N'importe qui ouvre un compte et obtient
/// `<le sien>.supabase.co`, qui passait la garde exactement comme le nôtre —
/// donc le contrôle d'origine ne protégeait pas du cas qu'il vise.
@Suite("Un projet Supabase tiers n'est pas notre stockage")
struct CRMOriginPolicyStorageHostTests {

    @Test("Le projet Castral est accepté")
    func theCastralProjectIsApproved() {
        let verdict = CRMOriginPolicy.uploadDestination(
            "https://nifvrjlcurdqzdwvwfxh.supabase.co/storage/v1/object/upload/x?token=abc",
            crmHost: "crm.castral.fr"
        )
        #expect(verdict.url != nil)
    }

    @Test("Un autre projet du même hébergeur est refusé")
    func anotherProjectOnTheSameHostIsRefused() {
        let verdict = CRMOriginPolicy.uploadDestination(
            "https://attaquant.supabase.co/storage/v1/object/upload/x?token=abc",
            crmHost: "crm.castral.fr"
        )
        #expect(verdict.refusal == .unapprovedHost("attaquant.supabase.co"))
    }

    @Test("Le domaine nu de l'hébergeur est refusé aussi")
    func theBareHostingDomainIsRefused() {
        #expect(
            CRMOriginPolicy.uploadDestination("https://supabase.co/x", crmHost: nil).refusal
                == .unapprovedHost("supabase.co")
        )
    }

    @Test("Un hôte qui imite le nôtre par suffixe est refusé")
    func aLookalikeSuffixIsRefused() {
        #expect(
            CRMOriginPolicy.uploadDestination(
                "https://nifvrjlcurdqzdwvwfxh.supabase.co.attaquant.fr/x", crmHost: nil
            ).refusal == .unapprovedHost("nifvrjlcurdqzdwvwfxh.supabase.co.attaquant.fr")
        )
    }
}

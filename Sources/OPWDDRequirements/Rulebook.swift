import Foundation

/// The versioned OPWDD rulebook, bundled as data (never code). Compiled from
/// official sources only — every requirement cites where it comes from, and
/// thresholds OPWDD doesn't publish are marked `interpretation: true` so the
/// UI can say "Kit's working interpretation," never "OPWDD requires."
/// Source of truth: kithome/data/opwdd-rulebook/ny-v1/rulebook.json.

struct Rulebook: Codable {
    let rulebookVersion: String
    let jurisdiction: String
    let program: String
    let compiledAt: String
    let legalBasis: String?
    let sources: [RuleSource]
    let evidenceCategories: [String]
    let stages: [StageInfo]
    let acceptableInstruments: [String: [String]]
    let requirements: [Requirement]

    struct RuleSource: Codable {
        let id: String
        let title: String
        let url: String
        let retrieved: String
        let sha256: String?
    }

    struct StageInfo: Codable {
        let id: String
        let parentLabel: String
        let band: String
    }

    struct Requirement: Codable, Identifiable {
        let id: String
        let kind: Kind
        let requiredLevel: Level
        let appliesWhen: AppliesWhen?
        let stages: [String]
        let title: String
        let parentLabel: String
        let evidenceCategory: String
        let decisionLogic: String?
        let attributes: [AttributeRule]?
        let recency: RecencyRule?
        let signatureRequired: Bool?
        let allAvailable: Bool?
        let satisfiableByOtherReports: Bool?
        let citations: [Citation]
        let explanations: [String: String]

        enum Kind: String, Codable { case evidence, administrative, interpretive }
        enum Level: String, Codable { case required, helpful }

        struct AppliesWhen: Codable { let diagnosisBasis: String? }

        struct AttributeRule: Codable {
            let key: String
            let anyOf: [String]?
            let anyOfRef: [String]?
            let noneOfRef: [String]?
            let matchFields: [String]
            let failReason: String
            let optional: Bool?
        }

        struct RecencyRule: Codable {
            let maxAgeMonths: Int
            let anchor: String           // "assessmentDate" | "reportDate"
            let hard: Bool
            let interpretation: Bool
            let note: String
        }

        struct Citation: Codable {
            let sourceId: String
            let `where`: String
        }
    }
}

extension Rulebook {
    /// Terms an attribute rule accepts, with instrument references resolved.
    func resolvedAnyOf(for rule: Requirement.AttributeRule) -> [String] {
        var terms = rule.anyOf ?? []
        for ref in rule.anyOfRef ?? [] { terms += acceptableInstruments[ref] ?? [] }
        return terms
    }

    func resolvedNoneOf(for rule: Requirement.AttributeRule) -> [String] {
        var terms: [String] = []
        for ref in rule.noneOfRef ?? [] { terms += acceptableInstruments[ref] ?? [] }
        return terms
    }

    func source(id: String) -> RuleSource? { sources.first { $0.id == id } }
    func stageInfo(_ stage: CaseStage) -> StageInfo? { stages.first { $0.id == stage.rawValue } }

    /// Loads the bundled rulebook. Hard-fails in DEBUG if missing — a build
    /// without its rulebook is a build that can't keep its promises.
    /// The one edit made when extracting this engine from the shipped iOS app:
    /// the app reads the rulebook from `Bundle.main`, the package reads it from
    /// `Bundle.module`. The rulebook JSON itself is byte-identical to the file
    /// shipped in the app.
    static func load(bundle: Bundle = .module) -> Rulebook? {
        guard let url = bundle.url(forResource: "opwdd-rulebook-ny-v1", withExtension: "json"),
              let data = try? Data(contentsOf: url) else {
            assertionFailure("opwdd-rulebook-ny-v1.json missing from bundle")
            return nil
        }
        do {
            return try JSONDecoder().decode(Rulebook.self, from: data)
        } catch {
            assertionFailure("Rulebook decode failed: \(error)")
            return nil
        }
    }

    static func load(from url: URL) throws -> Rulebook {
        try JSONDecoder().decode(Rulebook.self, from: Data(contentsOf: url))
    }
}

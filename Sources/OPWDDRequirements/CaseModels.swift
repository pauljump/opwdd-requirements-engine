import Foundation

/// The Case layer: Kit's durable, local-only record of one child's documents,
/// the cited facts inside them, and the parent's corrections. The LLM extracts;
/// it never decides. Requirement mapping is pure Swift over the bundled,
/// versioned OPWDD rulebook (see RequirementEngine). Corrections are
/// append-only events; every screen renders from the derived "effective" view,
/// so one correction propagates everywhere with no invalidation bookkeeping.

// MARK: - Vocabulary (closed; mirrors the rulebook + server contract)

enum EvidenceCategory: String, Codable, CaseIterable {
    case psychologicalIntellectual = "psychological_intellectual"
    case adaptiveBehavior = "adaptive_behavior"
    case asdComprehensiveEval = "asd_comprehensive_eval"
    case medicalRecent = "medical_recent"
    case medicalSpecialty = "medical_specialty"
    case developmentalSocialHistory = "developmental_social_history"
    case socialEvaluationRecent = "social_evaluation_recent"
    case schoolIEP = "school_iep"
    case mentalHealthRecords = "mental_health_records"
    case opwddCorrespondence = "opwdd_correspondence"
    case opwddForm = "opwdd_form"
    case other
}

enum CaseStage: String, Codable, CaseIterable {
    case frontDoor = "front_door"
    case initialEligibility = "initial_eligibility"
    case additionalInformationRequested = "additional_information_requested"
    case secondStepReview = "second_step_review"
    case thirdStepReviewOrFairHearing = "third_step_review_or_fair_hearing"
    case eligibilityDetermined = "eligibility_determined"
    case levelOfCare = "level_of_care"
    case medicaidWaiver = "medicaid_waiver"
    case serviceAuthorization = "service_authorization"
    case selfDirectionOrFSS = "self_direction_or_fss"
    case unknownStage = "unknown_stage"
}

enum VersionState: String, Codable {
    case draft, final, signed, unsigned, addendum, amended, superseded, unknown
}

// MARK: - Document identity (what the document IS, before what it says)

/// Each non-nil field carries a cited basis (identityBasis) so "FINAL, signed"
/// is something Kit read on a page, not a guess. Filename is never identity —
/// the document id is the SHA-256 of its bytes.
struct IdentityBasis: Codable {
    let field: String          // "docType", "assessmentDate", "versionState"…
    let sourceQuote: String
    var grounding: ExtractedFact.Grounding?
}

struct DocumentIdentity: Codable {
    var docType: String?
    var subjectName: String?
    var authorName: String?
    var authorCredential: String?
    var organization: String?
    var assessmentDate: String?   // ISO yyyy-mm-dd when determinable
    var reportDate: String?       // ISO
    var versionState: VersionState = .unknown
    var evidenceCategories: [EvidenceCategory] = []
    var stageHint: CaseStage?
    var identityBasis: [IdentityBasis] = []
}

// MARK: - Facts

struct CaseFact: Codable, Identifiable {
    let id: String                // "\(docID)#\(index)" — stable; corrections reference it
    var label: String
    var value: String
    var sourceQuote: String
    var page: Int?
    var confidence: ExtractedFact.Confidence
    var grounding: ExtractedFact.Grounding?
    var evidenceCategory: EvidenceCategory?
    var attributes: [String: String]?   // e.g. ["instrument": "WISC-V", "score": "72"]
}

struct CaseDocument: Codable, Identifiable {
    let id: String                // SHA-256 of the PDF bytes — content identity
    var fileName: String          // display hint only, never identity
    var importedAt: Date
    var pageCount: Int?
    var hadTextLayer: Bool
    var identity: DocumentIdentity
    var insight: String?
    var facts: [CaseFact]
    var rulebookVersion: String   // pinned at extraction time
}

// MARK: - Corrections (append-only; the feedback moat)

/// The parent's plain-language actions. Truth tier and error lane are computed
/// from the action + target in code — the parent never sees those words.
enum CorrectionAction: Codable, Equatable {
    case confirm
    case edit(newValue: String)
    case rejectNotInDocument
    case wrongPerson
    case outdated                              // a newer version supersedes this
    case wrongDocumentType(newType: String?)
    case duplicate(ofDocumentID: String?)
    case wrongStage(newStage: CaseStage?)
}

enum CorrectionTarget: Codable, Equatable {
    case fact(documentID: String, factID: String)
    case identityField(documentID: String, field: String)
    case document(documentID: String)
}

enum ErrorLane: String, Codable { case ingestion, extraction, evidenceMapping = "evidence_mapping", advice }

struct CorrectionEvent: Codable, Identifiable {
    var id = UUID()
    var date = Date()
    var target: CorrectionTarget
    var action: CorrectionAction
    var originalValue: String?
    var truthTier: Int
    var errorLane: ErrorLane

    init(target: CorrectionTarget, action: CorrectionAction, originalValue: String? = nil) {
        self.target = target
        self.action = action
        self.originalValue = originalValue
        self.truthTier = Self.tier(for: action, target: target)
        self.errorLane = Self.lane(for: action, target: target)
    }

    /// Tier 1 = mechanical document truth; Tier 2 = family/process context.
    /// Tier 3 (clinical/legal interpretation) is never reachable by a parent
    /// action — interpretive requirements cap at needs_qualified_review.
    static func tier(for action: CorrectionAction, target: CorrectionTarget) -> Int {
        switch action {
        case .confirm, .edit, .rejectNotInDocument, .wrongDocumentType: return 1
        case .wrongPerson, .outdated, .duplicate, .wrongStage: return 2
        }
    }

    static func lane(for action: CorrectionAction, target: CorrectionTarget) -> ErrorLane {
        switch action {
        case .edit, .rejectNotInDocument, .wrongDocumentType: return .extraction
        case .wrongPerson, .outdated, .duplicate, .wrongStage: return .evidenceMapping
        case .confirm: return .extraction
        }
    }
}

// MARK: - Case state (persisted) and effective view (derived)

struct CaseState: Codable {
    var schemaVersion = 1
    var childName: String?
    var stage: CaseStage = .unknownStage
    var stageSetByParent = false
    var documents: [CaseDocument] = []
    var corrections: [CorrectionEvent] = []
}

/// A document after the corrections fold: values edited, rejected facts removed
/// (raw kept in CaseState), quarantine/supersede/duplicate flags applied.
struct EffectiveDocument: Identifiable {
    var base: CaseDocument
    var facts: [CaseFact]               // post-corrections
    var quarantined = false             // "different child" — out of the subject graph
    var duplicateOf: String?
    var confirmedFactIDs: Set<String> = []
    var id: String { base.id }

    /// In the running for requirement mapping?
    var mappable: Bool {
        !quarantined && duplicateOf == nil && base.identity.versionState != .superseded
    }
}

struct EffectiveCaseState {
    var childName: String?
    var stage: CaseStage
    var documents: [EffectiveDocument]

    /// Diagnosis-basis heuristic for `appliesWhen` rules: conservative — turning
    /// a conditional requirement ON adds a checklist row; it never asserts anything.
    var diagnosisBases: Set<String> {
        var bases: Set<String> = []
        let text = documents.filter(\.mappable)
            .flatMap { $0.facts.map { "\($0.label) \($0.value)" } + [$0.base.identity.docType ?? ""] }
            .joined(separator: " ").lowercased()
        if text.contains("autism") || text.contains("asd") || text.contains("f84") {
            bases.insert("autism")
            bases.insert("other_than_intellectual_disability")
        }
        if text.contains("cerebral palsy") || text.contains("epilepsy") || text.contains("seizure")
            || text.contains("prader-willi") || text.contains("dysautonomia") || text.contains("neurological") {
            bases.insert("other_than_intellectual_disability")
        }
        return bases
    }
}

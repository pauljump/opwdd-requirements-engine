import Foundation

/// The correction fold, extracted from the shipped app's `CaseStore.swift`.
///
/// The app's `CaseStore` is an App Group, file-backed, `completeFileProtection`
/// store that also owns the network path to the extraction service. None of that
/// is needed to reason about requirements, and none of it belongs in a public
/// repository, so only the two pure functions are vendored here, verbatim.
///
/// This is the append-only correction model: documents and corrections are both
/// immutable facts, and the "effective" view is derived by replaying corrections
/// in date order. A parent fixes something once and every dependent output, the
/// checklist, the gap, the draft form, re-derives from the corrected view.

enum CaseStore {

    nonisolated static func fold(documents: [CaseDocument], corrections: [CorrectionEvent]) -> [EffectiveDocument] {
        var effective: [String: EffectiveDocument] = [:]
        for doc in documents {
            effective[doc.id] = EffectiveDocument(base: doc, facts: doc.facts)
        }

        for event in corrections.sorted(by: { $0.date < $1.date }) {
            switch event.target {

            case .fact(let docID, let factID):
                guard var doc = effective[docID],
                      let idx = doc.facts.firstIndex(where: { $0.id == factID }) else { continue }
                switch event.action {
                case .confirm:
                    doc.confirmedFactIDs.insert(factID)
                case .edit(let newValue):
                    doc.facts[idx].value = newValue
                    doc.confirmedFactIDs.insert(factID)
                case .rejectNotInDocument:
                    doc.facts.remove(at: idx)
                default:
                    break
                }
                effective[docID] = doc

            case .identityField(let docID, let field):
                guard var doc = effective[docID] else { continue }
                switch event.action {
                case .edit(let newValue):
                    doc.base.identity = Self.applying(field: field, value: newValue, to: doc.base.identity)
                case .confirm:
                    break
                default:
                    break
                }
                effective[docID] = doc

            case .document(let docID):
                guard var doc = effective[docID] else { continue }
                switch event.action {
                case .wrongPerson:
                    doc.quarantined = true
                case .outdated:
                    doc.base.identity.versionState = .superseded
                case .duplicate(let ofID):
                    doc.duplicateOf = ofID ?? "unspecified"
                case .wrongDocumentType(let newType):
                    doc.base.identity.docType = newType ?? doc.base.identity.docType
                case .wrongStage(let newStage):
                    doc.base.identity.stageHint = newStage
                default:
                    break
                }
                effective[docID] = doc
            }
        }

        // Stable order: as imported.
        return documents.compactMap { effective[$0.id] }
    }

    private nonisolated static func applying(field: String, value: String, to identity: DocumentIdentity) -> DocumentIdentity {
        var id = identity
        switch field {
        case "docType": id.docType = value
        case "subjectName": id.subjectName = value
        case "authorName": id.authorName = value
        case "authorCredential": id.authorCredential = value
        case "organization": id.organization = value
        case "assessmentDate": id.assessmentDate = value
        case "reportDate": id.reportDate = value
        case "versionState": id.versionState = VersionState(rawValue: value) ?? id.versionState
        default: break
        }
        return id
    }
}

import XCTest
@testable import OPWDDRequirements

/// The product promise under test: "correct this once, and it is fixed
/// everywhere." Each of the parent's actions is folded and the downstream
/// requirement view must move accordingly — no manual invalidation anywhere.
final class CorrectionPropagationTests: XCTestCase {

    var rulebook: Rulebook!
    let now = RequirementEngine.parseISO("2026-06-11")!

    override func setUpWithError() throws {
        rulebook = try XCTUnwrap(Rulebook.load())
    }

    func wisc(id: String = "wisc") -> CaseDocument {
        var identity = DocumentIdentity()
        identity.docType = "Neuropsychological evaluation"
        identity.subjectName = "Subject A"
        identity.assessmentDate = "2025-11-20"
        identity.versionState = .signed
        identity.evidenceCategories = [.psychologicalIntellectual]
        let facts = [
            CaseFact(id: "\(id)#0", label: "Full Scale IQ", value: "WISC-V Full Scale IQ 72",
                     sourceQuote: "Full Scale IQ: 72", page: 4, confidence: .high, grounding: .quote,
                     evidenceCategory: .psychologicalIntellectual, attributes: ["instrument": "WISC-V"]),
            CaseFact(id: "\(id)#1", label: "Diagnosis", value: "Autism Spectrum Disorder",
                     sourceQuote: "meets DSM-5-TR criteria for ASD", page: 9, confidence: .high, grounding: .quote,
                     evidenceCategory: .psychologicalIntellectual, attributes: nil)
        ]
        return CaseDocument(id: id, fileName: "eval.pdf", importedAt: Date(timeIntervalSince1970: 0),
                            pageCount: 12, hadTextLayer: true, identity: identity,
                            insight: nil, facts: facts, rulebookVersion: rulebook.rulebookVersion)
    }

    func cognitiveState(docs: [CaseDocument], corrections: [CorrectionEvent]) -> MappingState {
        let state = EffectiveCaseState(childName: "Sam", stage: .initialEligibility,
                                       documents: CaseStore.fold(documents: docs, corrections: corrections))
        let statuses = RequirementEngine.evaluate(rulebook: rulebook, state: state, now: now)
        return statuses.first { $0.requirement.id == "REQ-ELIG-COGNITIVE" }!.state
    }

    func testBaselineSupported() {
        XCTAssertEqual(cognitiveState(docs: [wisc()], corrections: []), .supported)
    }

    func testOutdatedFlipsSupportedToStale() {
        let correction = CorrectionEvent(target: .document(documentID: "wisc"), action: .outdated)
        XCTAssertEqual(cognitiveState(docs: [wisc()], corrections: [correction]), .staleOrWrongStage,
                       "superseded doc is sidelined; requirement reads stale, not supported")
        XCTAssertEqual(correction.truthTier, 2)
        XCTAssertEqual(correction.errorLane, .evidenceMapping)
    }

    func testWrongPersonQuarantinesDocument() {
        let correction = CorrectionEvent(target: .document(documentID: "wisc"), action: .wrongPerson)
        XCTAssertEqual(cognitiveState(docs: [wisc()], corrections: [correction]), .staleOrWrongStage)
        let folded = CaseStore.fold(documents: [wisc()], corrections: [correction])
        XCTAssertTrue(folded[0].quarantined)
        XCTAssertFalse(folded[0].mappable)
    }

    func testRejectFactRemovesItsSupport() {
        let correction = CorrectionEvent(target: .fact(documentID: "wisc", factID: "wisc#0"),
                                         action: .rejectNotInDocument,
                                         originalValue: "WISC-V Full Scale IQ 72")
        let state = cognitiveState(docs: [wisc()], corrections: [correction])
        XCTAssertNotEqual(state, .supported, "the score fact carried the instrument + full-scores match")
        XCTAssertEqual(correction.truthTier, 1)
        XCTAssertEqual(correction.errorLane, .extraction)
    }

    func testEditIdentityDateRescuesStaleDocument() {
        var doc = wisc()
        doc.identity.assessmentDate = "2021-01-01"   // misread by extraction
        XCTAssertEqual(cognitiveState(docs: [doc], corrections: []), .staleOrWrongStage)

        let fix = CorrectionEvent(target: .identityField(documentID: "wisc", field: "assessmentDate"),
                                  action: .edit(newValue: "2025-11-20"),
                                  originalValue: "2021-01-01")
        XCTAssertEqual(cognitiveState(docs: [doc], corrections: [fix]), .supported,
                       "one date fix re-derives the whole requirement view")
    }

    func testDuplicateCollapses() {
        let original = wisc(id: "wisc")
        let dupe = wisc(id: "wisc-dupe")
        let correction = CorrectionEvent(target: .document(documentID: "wisc-dupe"),
                                         action: .duplicate(ofDocumentID: "wisc"))
        let folded = CaseStore.fold(documents: [original, dupe], corrections: [correction])
        XCTAssertEqual(folded.filter(\.mappable).count, 1)
    }

    func testConfirmMarksFactReviewed() {
        let correction = CorrectionEvent(target: .fact(documentID: "wisc", factID: "wisc#1"), action: .confirm)
        let folded = CaseStore.fold(documents: [wisc()], corrections: [correction])
        XCTAssertTrue(folded[0].confirmedFactIDs.contains("wisc#1"))
    }

    func testEditFactValueReplacesAndMarksReviewed() {
        let correction = CorrectionEvent(target: .fact(documentID: "wisc", factID: "wisc#0"),
                                         action: .edit(newValue: "WISC-V Full Scale IQ 73"),
                                         originalValue: "WISC-V Full Scale IQ 72")
        let folded = CaseStore.fold(documents: [wisc()], corrections: [correction])
        XCTAssertEqual(folded[0].facts.first { $0.id == "wisc#0" }?.value, "WISC-V Full Scale IQ 73")
        XCTAssertTrue(folded[0].confirmedFactIDs.contains("wisc#0"))
    }

    func testWrongDocumentTypeAndStageHint() {
        let typeFix = CorrectionEvent(target: .document(documentID: "wisc"),
                                      action: .wrongDocumentType(newType: "School psychoeducational report"))
        let stageFix = CorrectionEvent(target: .document(documentID: "wisc"),
                                       action: .wrongStage(newStage: .eligibilityDetermined))
        let folded = CaseStore.fold(documents: [wisc()], corrections: [typeFix, stageFix])
        XCTAssertEqual(folded[0].base.identity.docType, "School psychoeducational report")
        XCTAssertEqual(folded[0].base.identity.stageHint, .eligibilityDetermined)
    }
}

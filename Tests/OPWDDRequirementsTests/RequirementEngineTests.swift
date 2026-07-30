import XCTest
@testable import OPWDDRequirements

/// Deterministic engine tests. `now` is injected; no I/O beyond loading the
/// bundled rulebook from the host app.
final class RequirementEngineTests: XCTestCase {

    var rulebook: Rulebook!
    /// A fixed "today" for every test: 2026-06-11.
    let now = RequirementEngine.parseISO("2026-06-11")!

    override func setUpWithError() throws {
        rulebook = try XCTUnwrap(Rulebook.load(), "bundled rulebook must load")
    }

    // MARK: - Fixtures

    func makeDoc(id: String = UUID().uuidString,
                 docType: String,
                 categories: [EvidenceCategory],
                 assessmentDate: String?,
                 versionState: VersionState = .signed,
                 facts: [(label: String, value: String, instrument: String?)]) -> CaseDocument {
        var identity = DocumentIdentity()
        identity.docType = docType
        identity.subjectName = "Subject A"
        identity.assessmentDate = assessmentDate
        identity.versionState = versionState
        identity.evidenceCategories = categories
        let caseFacts = facts.enumerated().map { i, f in
            CaseFact(id: "\(id)#\(i)", label: f.label, value: f.value,
                     sourceQuote: f.value, page: 1, confidence: .high, grounding: .quote,
                     evidenceCategory: categories.first,
                     attributes: f.instrument.map { ["instrument": $0] })
        }
        return CaseDocument(id: id, fileName: "\(docType).pdf", importedAt: Date(timeIntervalSince1970: 0),
                            pageCount: 10, hadTextLayer: true, identity: identity,
                            insight: nil, facts: caseFacts,
                            rulebookVersion: rulebook.rulebookVersion)
    }

    func effective(_ docs: [CaseDocument], stage: CaseStage) -> EffectiveCaseState {
        EffectiveCaseState(childName: "Sam", stage: stage,
                           documents: CaseStore.fold(documents: docs, corrections: []))
    }

    func status(_ id: String, in statuses: [RequirementStatus]) -> RequirementStatus? {
        statuses.first { $0.requirement.id == id }
    }

    func currentWISC(id: String = "wisc-current") -> CaseDocument {
        makeDoc(id: id, docType: "Neuropsychological evaluation",
                categories: [.psychologicalIntellectual],
                assessmentDate: "2025-11-20",
                facts: [("Full Scale IQ", "WISC-V Full Scale IQ 72", "WISC-V"),
                        ("Diagnosis", "Autism Spectrum Disorder", nil)])
    }

    // MARK: - Core states

    func testSupportedCognitive() {
        let state = effective([currentWISC()], stage: .initialEligibility)
        let s = status("REQ-ELIG-COGNITIVE", in: RequirementEngine.evaluate(rulebook: rulebook, state: state, now: now))!
        XCTAssertEqual(s.state, .supported)
        XCTAssertEqual(s.supportingDocumentIDs, ["wisc-current"])
        XCTAssertFalse(s.supportingFactIDs.isEmpty)
    }

    func testStaleCognitiveCarriesInterpretationFlag() {
        let old = makeDoc(docType: "Neuropsychological evaluation",
                          categories: [.psychologicalIntellectual],
                          assessmentDate: "2021-05-01",
                          facts: [("Full Scale IQ", "WISC-V Full Scale IQ 74", "WISC-V")])
        let state = effective([old], stage: .initialEligibility)
        let s = status("REQ-ELIG-COGNITIVE", in: RequirementEngine.evaluate(rulebook: rulebook, state: state, now: now))!
        XCTAssertEqual(s.state, .staleOrWrongStage)
        XCTAssertTrue(s.interpretationFlag, "soft 36mo cutoff is Kit's interpretation — must be flagged")
        XCTAssertTrue(s.reasons.joined().contains("interpretation"))
    }

    func testHardRecencyMedicalSummaryIsNotFlaggedAsInterpretation() {
        let oldMedical = makeDoc(docType: "Annual physical", categories: [.medicalRecent],
                                 assessmentDate: "2025-04-01", facts: [])
        let state = effective([oldMedical], stage: .initialEligibility)
        let s = status("REQ-ELIG-MEDICAL-SUMMARY", in: RequirementEngine.evaluate(rulebook: rulebook, state: state, now: now))!
        XCTAssertEqual(s.state, .staleOrWrongStage, "14 months old vs published 12-month rule")
        XCTAssertFalse(s.interpretationFlag, "12-month medical rule is OPWDD's own — not an interpretation")
    }

    func testNotFoundAndHonestGap() {
        let state = effective([], stage: .initialEligibility)
        let statuses = RequirementEngine.evaluate(rulebook: rulebook, state: state, now: now)
        XCTAssertEqual(status("REQ-ELIG-COGNITIVE", in: statuses)?.state, .notFoundInCurrentCorpus)
        XCTAssertEqual(RequirementEngine.honestGap(in: statuses)?.requirement.id, "REQ-ELIG-COGNITIVE")
    }

    func testLCEDRequirementsInvisibleAtInitialEligibility() {
        let state = effective([], stage: .initialEligibility)
        let statuses = RequirementEngine.evaluate(rulebook: rulebook, state: state, now: now)
        for id in ["REQ-LCED-PHYSICAL", "REQ-LCED-SOCIAL-EVAL", "REQ-LCED-PSYCH", "REQ-LCED-CRITERIA", "REQ-LCED-DD-ELIGIBILITY"] {
            XCTAssertEqual(status(id, in: statuses)?.state, .notApplicable, "\(id) must not surface pre-eligibility")
        }
    }

    func testEligibilityDeterminedShowsWaiverChecklist() {
        let state = effective([], stage: .eligibilityDetermined)
        let statuses = RequirementEngine.evaluate(rulebook: rulebook, state: state, now: now)
        XCTAssertEqual(status("REQ-LCED-PHYSICAL", in: statuses)?.state, .notFoundInCurrentCorpus)
        XCTAssertEqual(status("REQ-ELIG-COGNITIVE", in: statuses)?.state, .notApplicable,
                       "initial-eligibility checklist hides once eligibility is determined")
    }

    func testASDEvalIsConditionalOnAutismEvidence() {
        let noAutism = makeDoc(docType: "Physical", categories: [.medicalRecent],
                               assessmentDate: "2026-01-10", facts: [])
        var statuses = RequirementEngine.evaluate(
            rulebook: rulebook, state: effective([noAutism], stage: .initialEligibility), now: now)
        XCTAssertEqual(status("REQ-ELIG-ASD-EVAL", in: statuses)?.state, .notApplicable)

        statuses = RequirementEngine.evaluate(
            rulebook: rulebook, state: effective([currentWISC()], stage: .initialEligibility), now: now)
        XCTAssertNotEqual(status("REQ-ELIG-ASD-EVAL", in: statuses)?.state, .notApplicable,
                          "autism evidence in the corpus turns the requirement on")
    }

    func testAbbreviatedMeasureDoesNotSupport() {
        let wasi = makeDoc(docType: "Psychological screening", categories: [.psychologicalIntellectual],
                           assessmentDate: "2026-01-15",
                           facts: [("Score", "WASI-II estimated IQ 75", "WASI")])
        let state = effective([wasi], stage: .initialEligibility)
        let s = status("REQ-ELIG-COGNITIVE", in: RequirementEngine.evaluate(rulebook: rulebook, state: state, now: now))!
        XCTAssertNotEqual(s.state, .supported, "WASI is on OPWDD's not-comprehensive list")
    }

    func testContradictedDiagnosisAcrossDocuments() {
        let a = makeDoc(id: "a", docType: "Neuropsychological evaluation",
                        categories: [.psychologicalIntellectual], assessmentDate: "2025-10-01",
                        facts: [("Diagnosis", "Autism Spectrum Disorder", nil),
                                ("Full Scale IQ", "WISC-V Full Scale IQ 72", "WISC-V")])
        let b = makeDoc(id: "b", docType: "Psychological evaluation",
                        categories: [.psychologicalIntellectual], assessmentDate: "2025-12-01",
                        facts: [("Diagnosis", "ADHD, combined presentation", nil),
                                ("Full Scale IQ", "WISC-V Full Scale IQ 90", "WISC-V")])
        let state = effective([a, b], stage: .initialEligibility)
        let s = status("REQ-ELIG-COGNITIVE", in: RequirementEngine.evaluate(rulebook: rulebook, state: state, now: now))!
        XCTAssertEqual(s.state, .contradicted)
    }

    func testInterpretiveRequirementCapsAtNeedsQualifiedReview() {
        let doc = makeDoc(docType: "Neuropsychological evaluation",
                          categories: [.psychologicalIntellectual, .other],
                          assessmentDate: "2026-02-01",
                          facts: [("Diagnosis", "Autism Spectrum Disorder", nil),
                                  ("Adaptive functioning", "deficits in self-care and communication", nil)])
        let state = effective([doc], stage: .levelOfCare)
        let s = status("REQ-LCED-CRITERIA", in: RequirementEngine.evaluate(rulebook: rulebook, state: state, now: now))!
        XCTAssertEqual(s.state, .needsQualifiedReview, "Tier 3: evidence present but judgment is the QIDP's")
    }

    // MARK: - The frozen September 2025 backtest (engine-level)

    /// The four clinical evidence documents in the real September 8, 2025 packet,
    /// typed by hand as evidence shapes. No names, no dates of birth, no
    /// documents: an instrument, a score, a date, and a category is all the
    /// engine reads. Administrative items (the transmittal cover form) are
    /// deliberately absent, which is why the engine flags one.
    func septemberPacket() -> [CaseDocument] {
        [
            makeDoc(id: "np-2022", docType: "Neuropsychological evaluation",
                    categories: [.psychologicalIntellectual],
                    assessmentDate: "2022-03-15",
                    facts: [("Full Scale IQ", "WISC-V Full Scale IQ 74", "WISC-V"),
                            ("Diagnosis", "Autism Spectrum Disorder", nil)]),
            makeDoc(id: "vine-2022", docType: "Adaptive behavior assessment",
                    categories: [.adaptiveBehavior],
                    assessmentDate: "2022-03-20",
                    facts: [("Adaptive Behavior Composite", "Vineland-3 ABC 68", "Vineland-3")]),
            makeDoc(id: "psychosoc", docType: "Psychosocial history",
                    categories: [.developmentalSocialHistory, .socialEvaluationRecent],
                    assessmentDate: "2025-06-01",
                    facts: [("Developmental history", "delays evident in early childhood, before age 22", nil)]),
            makeDoc(id: "med-2025", docType: "Pediatric health form",
                    categories: [.medicalRecent],
                    assessmentDate: "2025-05-07", facts: []),
        ]
    }

    /// Reconstructs the shape of the real September 8, 2025 packet: dated
    /// cognitive/adaptive testing, a psychosocial that establishes onset, a
    /// current-enough medical form, and no comprehensive autism evaluation.
    /// OPWDD's real October 14, 2025 letter requested: current cognitive and
    /// adaptive testing, and a comprehensive autism evaluation. The engine
    /// must name all three from the pre-letter evidence alone, and must not
    /// flag what the packet did have.
    ///
    /// It is NOT true that the engine flags only those three. See
    /// `testSeptember2025BacktestFlagsNothingElseUnexplained` for the exact
    /// full set and why the two extra required flags are there.
    func testSeptember2025Backtest() {
        let sept2025 = RequirementEngine.parseISO("2025-09-08")!

        let state = effective(septemberPacket(), stage: .initialEligibility)
        let statuses = RequirementEngine.evaluate(rulebook: rulebook, state: state, now: sept2025)

        // The three gaps OPWDD's letter named:
        XCTAssertFalse(status("REQ-ELIG-COGNITIVE", in: statuses)!.state.isSatisfied,
                       "2022 cognitive testing should read as not current")
        XCTAssertFalse(status("REQ-ELIG-ADAPTIVE", in: statuses)!.state.isSatisfied,
                       "2022 adaptive testing should read as not current")
        XCTAssertFalse(status("REQ-ELIG-ASD-EVAL", in: statuses)!.state.isSatisfied,
                       "no comprehensive autism evaluation in the packet")

        // And what the packet DID have must not be flagged:
        XCTAssertTrue(status("REQ-ELIG-ONSET-HISTORY", in: statuses)!.state.isSatisfied)
        XCTAssertTrue(status("REQ-ELIG-MEDICAL-SUMMARY", in: statuses)!.state.isSatisfied,
                      "May 2025 medical form is within 12 months of September 2025")
        XCTAssertTrue(status("REQ-ELIG-SOCIAL-EVAL", in: statuses)!.state.isSatisfied)
    }

    /// The honest version of the backtest claim. The engine's recall against the
    /// letter is 3 of 3, but its output is not limited to those three, and any
    /// write-up that says "exactly those three" is wrong.
    ///
    /// This pins the complete unsatisfied set so the claim cannot drift:
    ///
    ///   - the three the letter named (cognitive, adaptive, ASD evaluation)
    ///   - REQ-ELIG-MEDICAL-SPECIALTY, a genuine extra flag: OPWDD's guidance
    ///     requires specialty documentation supporting the diagnosis, and the
    ///     letter did not ask for it. Counted as a false positive.
    ///   - REQ-ELIG-TRANSMITTAL, an artifact of the reconstruction rather than
    ///     an engine error: the transmittal form is an administrative cover
    ///     sheet, not a clinical document, so it was never typed into the
    ///     fixture. The real submission had one, or it would not have been
    ///     docketed at all.
    ///   - two `helpful` items (IEP, mental-health records), which are not
    ///     must-haves and are surfaced as such.
    func testSeptember2025BacktestFlagsNothingElseUnexplained() {
        let sept2025 = RequirementEngine.parseISO("2025-09-08")!
        let state = effective(septemberPacket(), stage: .initialEligibility)
        let statuses = RequirementEngine.evaluate(rulebook: rulebook, state: state, now: sept2025)

        let unsatisfiedRequired = Set(statuses
            .filter { !$0.state.isSatisfied && $0.requirement.requiredLevel == .required }
            .map(\.requirement.id))
        XCTAssertEqual(unsatisfiedRequired, [
            "REQ-ELIG-COGNITIVE",
            "REQ-ELIG-ADAPTIVE",
            "REQ-ELIG-ASD-EVAL",
            "REQ-ELIG-MEDICAL-SPECIALTY",
            "REQ-ELIG-TRANSMITTAL",
        ], "the required-level flagged set must stay exactly this")

        let unsatisfiedHelpful = Set(statuses
            .filter { !$0.state.isSatisfied && $0.requirement.requiredLevel == .helpful }
            .map(\.requirement.id))
        XCTAssertEqual(unsatisfiedHelpful, ["REQ-ELIG-IEP", "REQ-ELIG-MENTAL-HEALTH"])

        // Recall against the letter is what the case study claims: 3 of 3.
        let letterRequested = ["REQ-ELIG-COGNITIVE", "REQ-ELIG-ADAPTIVE", "REQ-ELIG-ASD-EVAL"]
        XCTAssertEqual(letterRequested.filter { unsatisfiedRequired.contains($0) }.count, 3)
    }

    /// Same corpus viewed nine months later: the medical form has crossed
    /// OPWDD's hard 12-month line and must flip to stale.
    func testMedicalFormExpiresByJune2026() {
        let medical = makeDoc(id: "med-2025", docType: "Pediatric health form",
                              categories: [.medicalRecent], assessmentDate: "2025-05-07", facts: [])
        let state = effective([medical], stage: .initialEligibility)
        let s = status("REQ-ELIG-MEDICAL-SUMMARY", in: RequirementEngine.evaluate(rulebook: rulebook, state: state, now: now))!
        XCTAssertEqual(s.state, .staleOrWrongStage)
    }

    // MARK: - Readiness verdict (the "where do I stand?" summary)

    /// The exact case that read as "no indication": a parent imports only an
    /// IEP. It maps to the HELPFUL school-records line and nothing else, so the
    /// verdict must read 0-of-N must-haves in place and point at cognitive
    /// testing as the biggest gap — not stay silent.
    func testReadinessWithOnlyAnIEPIsZeroInPlace() {
        let iep = makeDoc(docType: "Individualized Education Program",
                          categories: [.schoolIEP],
                          assessmentDate: "2026-01-10",
                          facts: [("Placement", "8:1+2 special class", nil)])
        let state = effective([iep], stage: .initialEligibility)
        let statuses = RequirementEngine.evaluate(rulebook: rulebook, state: state, now: now)
        let r = RequirementEngine.readiness(in: statuses)
        XCTAssertEqual(r.inPlace, 0, "an IEP satisfies no required eligibility evidence")
        XCTAssertGreaterThan(r.total, 0, "the stage has must-haves to count against")
        XCTAssertFalse(r.complete)
        XCTAssertEqual(r.biggestGap?.requirement.id, "REQ-ELIG-COGNITIVE")
    }

    /// An empty corpus still produces an honest, non-empty verdict.
    func testReadinessEmptyCorpus() {
        let statuses = RequirementEngine.evaluate(
            rulebook: rulebook, state: effective([], stage: .initialEligibility), now: now)
        let r = RequirementEngine.readiness(in: statuses)
        XCTAssertEqual(r.inPlace, 0)
        XCTAssertTrue(r.hasRequirements)
        XCTAssertNotNil(r.biggestGap)
    }

    /// Drawn from the real case record: the 2024 neuropsych UPDATE carries
    /// CELF-5 (speech) and KTEA-3 (achievement) scores but NO IQ battery,
    /// exactly why OPWDD's real October 2025 letter demanded current cognitive
    /// testing. The engine must read it as PARTWAY (right kind of document,
    /// missing the accepted instrument) and readiness must surface that —
    /// never an unexplained zero.
    func testNeuropsychUpdateWithoutIQBatteryIsPartway() {
        let update = makeDoc(docType: "Neuropsychological evaluation",
                             categories: [.psychologicalIntellectual, .asdComprehensiveEval],
                             assessmentDate: "2024-01-31",
                             facts: [("CELF-5: Sentence Comprehension", "Scaled Score 3, 1st percentile", "CELF-5"),
                                     ("KTEA-3: Reading Comprehension", "Standard Score 126, 96th percentile", "KTEA-3"),
                                     ("Diagnosis", "Autism Spectrum Disorder (ASD), longstanding", nil)])
        let state = effective([update], stage: .initialEligibility)
        let statuses = RequirementEngine.evaluate(rulebook: rulebook, state: state, now: now)

        let cognitive = status("REQ-ELIG-COGNITIVE", in: statuses)!
        XCTAssertEqual(cognitive.state, .partiallySupported,
                       "right category, no accepted IQ instrument → partway, not zero and not satisfied")
        XCTAssertFalse(cognitive.reasons.joined().isEmpty, "the why must be stated")

        let r = RequirementEngine.readiness(in: statuses)
        XCTAssertEqual(r.inPlace, 0)
        XCTAssertGreaterThanOrEqual(r.partway, 1, "the read document earns visible partial credit")
        XCTAssertEqual(r.biggestGap?.requirement.id, "REQ-ELIG-COGNITIVE")
    }

    /// "Are we eligible?" is answered by OPWDD's own paperwork: a document
    /// hinting a later stage (an eligibility letter) suggests the move; a
    /// document hinting an earlier stage, or a quarantined one, never
    /// drags the case backward.
    func testStageSuggestionFollowsDocuments() {
        var letter = makeDoc(docType: "OPWDD eligibility determination",
                             categories: [.opwddCorrespondence],
                             assessmentDate: "2026-03-04", facts: [])
        letter.identity.stageHint = .eligibilityDetermined

        var state = effective([letter], stage: .initialEligibility)
        XCTAssertEqual(RequirementEngine.suggestedStage(state: state), .eligibilityDetermined,
                       "an eligibility letter moves an 'applying' case forward")

        state = effective([letter], stage: .serviceAuthorization)
        XCTAssertNil(RequirementEngine.suggestedStage(state: state),
                     "a document behind the current stage never drags the case backward")

        let plain = makeDoc(docType: "IEP", categories: [.schoolIEP],
                            assessmentDate: "2026-01-10", facts: [])
        state = effective([plain], stage: .initialEligibility)
        XCTAssertNil(RequirementEngine.suggestedStage(state: state),
                     "no stage hint → no suggestion")
    }

    /// A genuine qualifying document moves the count and clears that gap.
    func testReadinessCountsSupportedMustHave() {
        let empty = RequirementEngine.readiness(
            in: RequirementEngine.evaluate(rulebook: rulebook,
                                           state: effective([], stage: .initialEligibility), now: now))
        let withWISC = RequirementEngine.readiness(
            in: RequirementEngine.evaluate(rulebook: rulebook,
                                           state: effective([currentWISC()], stage: .initialEligibility), now: now))
        XCTAssertGreaterThan(withWISC.inPlace, empty.inPlace,
                             "a current WISC must increase the in-place count")
        XCTAssertNotEqual(withWISC.biggestGap?.requirement.id, "REQ-ELIG-COGNITIVE",
                          "cognitive is no longer the gap once a current WISC is present")
    }
}

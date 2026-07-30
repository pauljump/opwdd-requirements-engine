import Foundation

/// The deterministic core: maps the effective case state against the rulebook.
/// PURE — no I/O, no Date() (now is injected), no model calls. The LLM never
/// reaches this layer; if a mapping is wrong, the fix is a parent correction
/// upstream or a rulebook edit, both auditable.
///
/// Failure direction is deliberate: when matching is ambiguous the engine
/// under-claims (partially_supported with a stated reason), never false
/// "supported" — a parent told "you're ready" who isn't is the worst outcome.

enum MappingState: String {
    case supported
    case partiallySupported = "partially_supported"
    case notFoundInCurrentCorpus = "not_found_in_current_corpus"
    case staleOrWrongStage = "stale_or_wrong_stage"
    case contradicted
    case needsQualifiedReview = "needs_qualified_review"
    case notApplicable = "not_applicable"
    case ruleUncertain = "rule_uncertain"

    /// Does this state count as "covered" for the checklist?
    var isSatisfied: Bool { self == .supported || self == .notApplicable || self == .needsQualifiedReview }
}

struct RequirementStatus: Identifiable {
    let requirement: Rulebook.Requirement
    let state: MappingState
    let supportingDocumentIDs: [String]
    let supportingFactIDs: [String]
    let reasons: [String]            // plain-language, from explanation templates
    let suggestedAsk: String?
    let interpretationFlag: Bool     // recency etc. was Kit's interpretation, not OPWDD's text
    var id: String { requirement.id }
}

enum RequirementEngine {

    static func evaluate(rulebook: Rulebook, state: EffectiveCaseState, now: Date) -> [RequirementStatus] {
        let bases = state.diagnosisBases
        return rulebook.requirements.map { req in
            evaluateOne(req, rulebook: rulebook, state: state, bases: bases, now: now)
        }
    }

    /// The first honest gap: rulebook order, required-level, unsatisfied.
    static func honestGap(in statuses: [RequirementStatus]) -> RequirementStatus? {
        statuses.first { $0.requirement.requiredLevel == .required && !$0.state.isSatisfied }
    }

    /// The furthest stage any live document hints at, when it's beyond the
    /// parent's current setting. OPWDD's own paperwork outranks memory: a
    /// determination letter saying "eligible" should move the case forward —
    /// with one parent tap, never silently. Kit itself still never declares
    /// eligibility; it surfaces what the document says.
    static func suggestedStage(state: EffectiveCaseState) -> CaseStage? {
        let order = CaseStage.allCases
        func rank(_ s: CaseStage) -> Int {
            s == .unknownStage ? -1 : (order.firstIndex(of: s) ?? -1)
        }
        guard let best = state.documents.filter(\.mappable)
            .compactMap(\.base.identity.stageHint)
            .max(by: { rank($0) < rank($1) }),
            rank(best) > rank(state.stage) else { return nil }
        return best
    }

    /// A one-glance verdict over the whole checklist: how many of THIS stage's
    /// must-haves are in place, how many are PARTWAY (a document speaks to the
    /// requirement but doesn't yet have what OPWDD accepts — wrong instrument,
    /// stale, contradicted), and the single biggest gap. "In place" counts
    /// supported and needs-qualified-review — never partial/missing. The point
    /// is to answer "where do I stand?" honestly without ever saying
    /// "eligible" — and without giving zero credit for a document Kit read.
    struct Readiness {
        let inPlace: Int
        let partway: Int
        let total: Int                       // required & applicable at this stage
        let biggestGap: RequirementStatus?
        var stillNeeded: Int { max(0, total - inPlace) }
        var hasRequirements: Bool { total > 0 }
        var complete: Bool { total > 0 && stillNeeded == 0 }
    }

    static func readiness(in statuses: [RequirementStatus]) -> Readiness {
        let required = statuses.filter {
            $0.requirement.requiredLevel == .required && $0.state != .notApplicable
        }
        let inPlace = required.filter { $0.state.isSatisfied }.count
        let partway = required.filter {
            switch $0.state {
            case .partiallySupported, .staleOrWrongStage, .contradicted: return true
            default: return false
            }
        }.count
        return Readiness(inPlace: inPlace, partway: partway, total: required.count,
                         biggestGap: honestGap(in: statuses))
    }

    // MARK: - Single requirement

    private static func evaluateOne(_ req: Rulebook.Requirement,
                                    rulebook: Rulebook,
                                    state: EffectiveCaseState,
                                    bases: Set<String>,
                                    now: Date) -> RequirementStatus {

        func status(_ s: MappingState, docs: [String] = [], facts: [String] = [],
                    reasons: [String] = [], interpretation: Bool = false) -> RequirementStatus {
            RequirementStatus(requirement: req, state: s,
                              supportingDocumentIDs: docs, supportingFactIDs: facts,
                              reasons: reasons,
                              suggestedAsk: req.explanations["suggestedAsk"],
                              interpretationFlag: interpretation)
        }

        // 1. Stage filter — out-of-stage requirements are invisible, never gaps.
        guard req.stages.contains(state.stage.rawValue) else {
            return status(.notApplicable)
        }

        // 2. Conditional applicability (e.g. comprehensive ASD eval only when
        //    the evidence base suggests an autism basis).
        if let condition = req.appliesWhen?.diagnosisBasis, !bases.contains(condition) {
            return status(.notApplicable)
        }

        // 3. Candidates: mappable documents carrying this evidence category.
        let category = req.evidenceCategory
        let candidates = state.documents.filter { doc in
            doc.mappable && doc.base.identity.evidenceCategories.contains { $0.rawValue == category }
        }
        // Sidelined matches (superseded/quarantined/duplicate) inform stale-vs-missing.
        let sidelined = state.documents.filter { doc in
            !doc.mappable && doc.base.identity.evidenceCategories.contains { $0.rawValue == category }
        }

        // Cross-report satisfiability: a developmental history can live inside a
        // neuropsych. Widen candidates to any mappable doc whose facts hit the
        // requirement's terms.
        var pool = candidates
        if pool.isEmpty && (req.satisfiableByOtherReports ?? false) {
            pool = state.documents.filter { doc in
                doc.mappable && !matches(req.attributes ?? [], in: doc, rulebook: rulebook).matchedFacts.isEmpty
            }
        }

        if pool.isEmpty {
            if !sidelined.isEmpty {
                let doc = sidelined[0]
                let reason = render(req.explanations["stale_or_wrong_stage"], doc: doc,
                                    fallbackReason: "the copy Kit has was marked outdated or about someone else.")
                return status(.staleOrWrongStage, docs: [doc.id], reasons: [reason])
            }
            let reason = req.explanations["not_found_in_current_corpus"]
                ?? "Kit didn't find this in the documents it has."
            return status(.notFoundInCurrentCorpus, reasons: [reason])
        }

        // 4. Contradiction scan: two live documents in this category asserting
        //    different values for the same load-bearing label.
        if let conflict = contradiction(in: pool) {
            let reason = "Two documents disagree: \(conflict). Worth resolving before anything is submitted."
            return status(.contradicted, docs: pool.map(\.id), reasons: [reason])
        }

        // 5. Score each candidate; report the best.
        var best: (doc: EffectiveDocument, failures: [String], factIDs: [String],
                   recencyOnly: Bool, interpretation: Bool)?
        for doc in pool {
            var failures: [String] = []
            var interpretation = false

            let match = matches(req.attributes ?? [], in: doc, rulebook: rulebook)
            failures += match.failures

            var recencyFailed = false
            if let recency = req.recency {
                switch age(of: doc, anchor: recency.anchor, now: now) {
                case .months(let m) where m > recency.maxAgeMonths:
                    recencyFailed = true
                    interpretation = recency.interpretation
                    let dateStr = anchorDate(of: doc, anchor: recency.anchor) ?? "undated"
                    failures.append(recency.hard
                        ? "it was completed more than \(recency.maxAgeMonths) months ago (\(dateStr)) — OPWDD's published limit."
                        : "it is older than \(spoken(months: recency.maxAgeMonths)) — and reviewers often ask for newer testing (\(dateStr)). This cutoff is Kit's interpretation, not OPWDD's published rule.")
                case .unknown:
                    failures.append("Kit couldn't read the assessment date — worth confirming it.")
                case .months:
                    break
                }
            }

            if req.signatureRequired == true {
                switch doc.base.identity.versionState {
                case .draft, .unsigned:
                    failures.append("this copy looks like a \(doc.base.identity.versionState.rawValue) — OPWDD wants the final, signed report.")
                default: break
                }
            }

            let attrsFailed = !match.failures.isEmpty
            let candidate = (doc: doc, failures: failures, factIDs: match.matchedFacts,
                             recencyOnly: recencyFailed && !attrsFailed, interpretation: interpretation)
            if best == nil || candidate.failures.count < best!.failures.count {
                best = candidate
            }
            if failures.isEmpty { break }
        }

        guard let chosen = best else {
            return status(.notFoundInCurrentCorpus,
                          reasons: [req.explanations["not_found_in_current_corpus"] ?? "Not found yet."])
        }

        // Interpretive requirements never reach "supported": evidence presence
        // is real, but the judgment belongs to a qualified reviewer (Tier 3).
        if req.kind == .interpretive {
            let summary = chosen.factIDs.isEmpty ? "see the documents above" : "\(chosen.factIDs.count) relevant findings"
            let template = req.explanations["needs_qualified_review"] ?? "Evidence present — needs qualified review."
            return status(.needsQualifiedReview, docs: [chosen.doc.id], facts: chosen.factIDs,
                          reasons: [template.replacingOccurrences(of: "{evidenceSummary}", with: summary)])
        }

        if chosen.failures.isEmpty {
            let reason = render(req.explanations["supported"], doc: chosen.doc, fallbackReason: "")
            return status(.supported, docs: [chosen.doc.id], facts: chosen.factIDs, reasons: [reason])
        }

        // Recency-only failure reads as stale, not partial — different ask.
        if chosen.recencyOnly {
            let template = render(req.explanations["stale_or_wrong_stage"], doc: chosen.doc,
                                  fallbackReason: chosen.failures.joined(separator: " "))
            return status(.staleOrWrongStage, docs: [chosen.doc.id], facts: chosen.factIDs,
                          reasons: [substitute(template, reason: chosen.failures.joined(separator: " "), doc: chosen.doc)],
                          interpretation: chosen.interpretation)
        }

        let template = render(req.explanations["partially_supported"], doc: chosen.doc,
                              fallbackReason: chosen.failures.joined(separator: " "))
        return status(.partiallySupported, docs: [chosen.doc.id], facts: chosen.factIDs,
                      reasons: [substitute(template, reason: chosen.failures.joined(separator: " "), doc: chosen.doc)],
                      interpretation: chosen.interpretation)
    }

    // MARK: - Attribute matching

    private struct AttributeMatch {
        var failures: [String] = []
        var matchedFacts: [String] = []
    }

    private static func matches(_ rules: [Rulebook.Requirement.AttributeRule],
                                in doc: EffectiveDocument,
                                rulebook: Rulebook) -> AttributeMatch {
        var result = AttributeMatch()
        for rule in rules {
            let accept = rulebook.resolvedAnyOf(for: rule).map(normalize)
            let reject = rulebook.resolvedNoneOf(for: rule).map(normalize)

            var hit = false
            var rejectedOnly = false
            for field in rule.matchFields {
                for (text, factID) in haystack(for: field, in: doc) {
                    let t = normalize(text)
                    if accept.contains(where: { t.contains($0) }) {
                        hit = true
                        if let factID { result.matchedFacts.append(factID) }
                    } else if !reject.isEmpty, reject.contains(where: { t.contains($0) }) {
                        rejectedOnly = true
                    }
                }
            }
            if !hit && !(rule.optional ?? false) {
                var reason = rule.failReason
                if rejectedOnly {
                    reason = "Kit only found a brief or screening measure here — " + rule.failReason
                }
                result.failures.append(reason)
            }
        }
        result.matchedFacts = Array(Set(result.matchedFacts))
        return result
    }

    /// (text, factID?) pairs for one matchField path.
    private static func haystack(for field: String, in doc: EffectiveDocument) -> [(String, String?)] {
        switch field {
        case "identity.docType":
            return [(doc.base.identity.docType ?? "", nil)]
        case "facts.label":
            return doc.facts.map { ($0.label, $0.id) }
        case "facts.value":
            return doc.facts.map { ("\($0.value) \($0.sourceQuote)", $0.id) }
        case "facts.attributes.instrument":
            return doc.facts.compactMap { f in
                guard let instrument = f.attributes?["instrument"] else { return nil }
                return (instrument, f.id)
            }
        default:
            return []
        }
    }

    private static func normalize(_ s: String) -> String {
        s.lowercased()
            .replacingOccurrences(of: "–", with: "-")
            .replacingOccurrences(of: "—", with: "-")
    }

    // MARK: - Recency

    private enum Age { case months(Int), unknown }

    private static func anchorDate(of doc: EffectiveDocument, anchor: String) -> String? {
        let identity = doc.base.identity
        return (anchor == "reportDate" ? identity.reportDate ?? identity.assessmentDate
                                       : identity.assessmentDate ?? identity.reportDate)
    }

    private static func age(of doc: EffectiveDocument, anchor: String, now: Date) -> Age {
        guard let iso = anchorDate(of: doc, anchor: anchor), let date = parseISO(iso) else { return .unknown }
        let months = Calendar(identifier: .gregorian)
            .dateComponents([.month], from: date, to: now).month ?? 0
        return .months(max(0, months))
    }

    static func parseISO(_ s: String) -> Date? {
        let formats = ["yyyy-MM-dd", "yyyy-MM", "yyyy"]
        for format in formats {
            let f = DateFormatter()
            f.locale = Locale(identifier: "en_US_POSIX")
            f.timeZone = TimeZone(identifier: "UTC")
            f.dateFormat = format
            if let d = f.date(from: s) { return d }
        }
        return nil
    }

    // MARK: - Contradiction (modest by design: same label, different value,
    // load-bearing labels only — diagnosis-shaped)

    private static func contradiction(in docs: [EffectiveDocument]) -> String? {
        guard docs.count > 1 else { return nil }
        var byLabel: [String: Set<String>] = [:]
        for doc in docs {
            for f in doc.facts where normalize(f.label).contains("diagnos") {
                byLabel[normalize(f.label), default: []].insert(normalize(f.value))
            }
        }
        for (label, values) in byLabel where values.count > 1 {
            return "different \(label) statements (\(values.count) versions)"
        }
        return nil
    }

    // MARK: - Explanation templates

    private static func render(_ template: String?, doc: EffectiveDocument, fallbackReason: String) -> String {
        guard let template else { return fallbackReason }
        return substitute(template, reason: fallbackReason, doc: doc)
    }

    private static func substitute(_ template: String, reason: String, doc: EffectiveDocument) -> String {
        template
            .replacingOccurrences(of: "{docTitle}", with: doc.base.identity.docType ?? doc.base.fileName)
            .replacingOccurrences(of: "{assessmentDate}", with: doc.base.identity.assessmentDate ?? "undated")
            .replacingOccurrences(of: "{reason}", with: reason)
    }

    /// "36 months" reads as "3 years" in parent-facing copy.
    private static func spoken(months: Int) -> String {
        months % 12 == 0 ? "\(months / 12) years" : "\(months) months"
    }
}

import Foundation

/// Extracted verbatim from the shipped app's `DocumentEnrichment.swift`, which
/// also carries the on-device PDF extractor. Only this type is needed by the
/// requirement engine, so only this type is vendored here: the engine depends on
/// how a fact was grounded, not on how it was pulled out of a PDF.

struct ExtractedFact: Identifiable, Codable {
    var id = UUID()
    let label: String        // "Diagnosis", "Service mandate", "Score"…
    let value: String
    let sourceLine: String    // the citation — the exact text it came from
    let confidence: Confidence
    /// Server-verified grounding (nil on legacy/dev paths — rendered as today).
    var grounding: Grounding?

    enum Confidence: String, Codable { case high, medium, low }

    /// How the citation was checked against the document (see server verify.ts):
    /// quote = found verbatim in the text layer; page = visually read (checkbox,
    /// scan) and cited by page; unverified = quote NOT found — worth confirming.
    enum Grounding: String, Codable { case quote, page, unverified }
}

# OPWDD requirements engine

A deterministic engine that reads a set of documents and says which New York
OPWDD eligibility requirements they satisfy, which they do not, and why.

The point of the design is that no language model decides anything. Requirements
live in a versioned rulebook compiled from official OPWDD publications. The
engine is pure functions over that rulebook. A model may be used upstream to pull
facts out of a PDF, but the model never rules on eligibility, and every claim the
engine makes carries a citation back to the source document that authorizes it.

## Why this exists

Benefits eligibility is a domain where the expensive failure is quiet. Nobody
gets hurt by a fabricated citation, because a caseworker will catch that. People
get hurt when a packet goes in missing one piece of evidence, the agency sends an
additional-information letter, and months disappear. So the thing worth measuring
is not fluency. It is whether a system can name the missing evidence before the
agency does.

## The held-out test

`Tests/OPWDDRequirementsTests/RequirementEngineTests.swift` contains
`testSeptember2025Backtest`. It reconstructs a real New York eligibility packet
frozen to its September 8, 2025 state: dated 2022 cognitive testing, dated 2022
adaptive testing, a 2025 psychosocial that establishes onset before age 22, a
current medical form, and no comprehensive autism evaluation. The engine is
evaluated with `now = 2025-09-08`, before the outcome existed.

OPWDD's real additional-information letter, dated October 14, 2025, requested
current cognitive testing, current adaptive testing, and a comprehensive autism
evaluation.

The engine named all three. It also did not flag any of the three requirements the
packet did satisfy (onset history, medical summary, social evaluation), which is
the part that makes this a test rather than an anecdote: a system that flags
everything would "pass" on the three gaps and fail here.

The engine's output is not limited to those three, and it would be an overclaim to
say it flagged exactly what the letter asked for. The complete required-level
flagged set is five, pinned in
`testSeptember2025BacktestFlagsNothingElseUnexplained`:

| Requirement | In the letter? | |
|---|---|---|
| `REQ-ELIG-COGNITIVE` | yes | stale, 2022 testing |
| `REQ-ELIG-ADAPTIVE` | yes | stale, 2022 testing |
| `REQ-ELIG-ASD-EVAL` | yes | absent |
| `REQ-ELIG-MEDICAL-SPECIALTY` | no | a genuine extra flag |
| `REQ-ELIG-TRANSMITTAL` | no | an artifact of the fixture |

So: recall against the letter is 3 of 3, with two additional required-level flags.

`REQ-ELIG-MEDICAL-SPECIALTY` counts as a false positive. OPWDD's published
guidance does require specialty documentation supporting the diagnosis, and the
agency did not ask for it, so either the pediatric health form was read as
covering it or the reviewer did not press the point.

`REQ-ELIG-TRANSMITTAL` is a limitation of the reconstruction rather than an engine
error. The transmittal form is an administrative cover sheet, not a clinical
document, so it was never typed into the fixture. The real submission had one or it
would not have been docketed.

Two further items surfaced as `helpful` rather than required (IEP, mental-health
records) and are presented as optional, not as gaps.

### What this test is and is not

It is a deterministic engine-level test against a real, dated agency outcome that
the rulebook could not have been fit to, because the rulebook is compiled from
OPWDD's published guidance rather than from the letter.

It is not an end-to-end test. It runs on a reconstruction of the packet's
evidence shape, typed by hand, not on the original PDFs through the extraction
path. The document-extraction stage is measured separately and is not part of this
repository.

It is one case. Three gaps on one packet is a real result and a small sample.

And two of the three gaps (`REQ-ELIG-COGNITIVE`, `REQ-ELIG-ADAPTIVE`) turn on
recency thresholds that OPWDD does not publish as a hard number. Those are
flagged `interpretation: true` in the rulebook and surfaced in the app as a
working interpretation, never as "OPWDD requires." The backtest agreeing with the
letter is evidence those interpretations are calibrated. It is not proof they are
the agency's actual rule.

## The rulebook

`rulebook/ny-v1/rulebook.json`, version `ny-opwdd-2026.06-r1`, compiled
2026-06-11.

| | |
|---|---|
| Requirements | 16 (14 required, 2 helpful) |
| Kinds | 12 evidence, 3 administrative, 1 interpretive |
| Citations | 20, with every requirement carrying at least one |
| Stages modeled | 11, from front door through self-direction |
| Evidence categories | 12 |
| Recency rules | 9, of which 4 are hard OPWDD-published limits and 5 are flagged interpretations |
| Official sources | 5 |

Legal basis: NYS Mental Hygiene Law 1.03(22); 14 NYCRR 629.1, 630.5, 635-10.3;
42 CFR 441.

The three source PDFs OPWDD publishes as documents are committed under
`rulebook/ny-v1/sources/` with their SHA-256 hashes, so a reader can confirm the
rulebook was compiled from the same bytes:

```
shasum -a 256 -c rulebook/ny-v1/sources/sha256sums.txt
```

Rules that OPWDD publishes as a firm limit are marked `hard: true`. Thresholds
that OPWDD leaves to judgment are marked `interpretation: true`. That distinction
is the whole reason the rulebook is data instead of code: it can be re-compiled
when the agency republishes, and it can be argued with.

## Design

Three states a requirement can be in, and the third is the one that matters:

- **satisfied** or **not satisfied**, the ordinary cases
- **needsQualifiedReview**, meaning the evidence is present but the judgment
  belongs to a qualified professional, not to this engine

The engine also distinguishes "no evidence" from "wrong evidence" from "stale
evidence," because those send a family to three different next actions. A
requirement that is `partway` (right kind of document, missing the accepted
instrument) reads differently from one with nothing against it. See
`testNeuropsychUpdateWithoutIQBatteryIsPartway`: a neuropsych update carrying
speech and achievement scores but no IQ battery is not a cognitive evaluation, and
saying so precisely is more useful than a zero.

Corrections are append-only. Documents and corrections are both immutable, and
the effective view is derived by replaying corrections in date order
(`Sources/OPWDDRequirements/CorrectionFold.swift`). A person fixes a fact once and
the checklist, the gap, and the draft form all re-derive. Nine tests in
`CorrectionPropagationTests` pin the propagation of each correction action.

## Run it

```
swift test
```

27 tests, no network, no API keys, no fixtures beyond the rulebook. A captured run
is in `artifacts/test-receipt.txt`.

## Provenance and scope

This engine is extracted from a shipped iOS app. Two changes were made in
extraction, both noted in the source:

1. `Rulebook.load()` reads from `Bundle.module` instead of `Bundle.main`. The
   rulebook JSON is byte-identical to the file shipped in the app.
2. `CaseStore.fold` and its helper are vendored into `CorrectionFold.swift`. The
   app's full `CaseStore` is an App Group, file-protected store that also owns the
   network path to the extraction service. None of that is needed to reason about
   requirements.

Deliberately not here: the document extraction path, the UI, the network layer,
and every test that touches real records. Test fixtures are synthetic.

This repository contains no personal, medical, or family records. The backtest is
a hand-typed reconstruction of an evidence shape, with no names, dates of birth,
scores tied to a person, or documents.

## Limits worth stating plainly

This engine does not determine eligibility. OPWDD does. It prepares and explains,
it recites the rule and cites the document, and it hands every judgment call that
requires a credential to a person who has one.

New York only. One rulebook version. One backtested case.

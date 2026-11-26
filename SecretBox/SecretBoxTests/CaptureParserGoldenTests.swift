import Foundation
import XCTest
@testable import SecretBox

/// The shared capture corpus is also run by the server tests. These tests are
/// deliberately independent of SecretBoxAppModel: capture is a pure engine,
/// and must work away from the main actor as well as in the app's preview.
final class CaptureParserGoldenTests: XCTestCase {
    private struct Case: Decodable, Sendable {
        let id: String
        let source: String
        let text: String
        let secrets: [String]
        let template: String
    }

    private struct SwiftFloors: Decodable, Sendable {
        let found: Int
        let primary: Int
        let template: Int
        let secondaryCases: Int
        let secondary: Int
        let negatives: Int
        let falsePositives: Int
        let leaks: Int
        let determinismRuns: Int

        enum CodingKeys: String, CodingKey {
            case found, primary, template, secondary, negatives, leaks
            case secondaryCases = "secondary_cases"
            case falsePositives = "false_positives"
            case determinismRuns = "determinism_runs"
        }
    }

    private struct Floors: Decodable, Sendable {
        let swift: SwiftFloors
    }

    private struct Corpus: Decodable, Sendable {
        let cases: [Case]
        let floors: Floors
    }

    private struct Metrics: Sendable {
        var found = 0
        var primary = 0
        var template = 0
        var secondaryCases = 0
        var secondary = 0
        var negatives = 0
        var falsePositives = 0
        var leaks = 0
        var missed: [String] = []
        var wrongPrimary: [String] = []
        var wrongTemplate: [String] = []
        var secondaryMissed: [String] = []
        var leaked: [String] = []
        var falsePositiveIDs: [String] = []
    }

    func testSecretOverrideKeepsTheFieldConcealed() {
        let capture = CaptureParser.parse(
            "host=redis.internal\npassword=Primary#1\nREDIS_AUTH=Secondary#2",
            overrides: ["redis_auth": "Changed#3"]
        )
        let field = capture.fields.first { $0.key == "redis_auth" }
        XCTAssertEqual(field?.value, "Changed#3")
        XCTAssertTrue(field?.hidden == true)
        XCTAssertFalse(capture.fields.contains { !$0.hidden && $0.value.contains("Changed#3") })
    }

    private func loadCorpus() throws -> Corpus {
        let testsDirectory = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        let repository = testsDirectory.deletingLastPathComponent().deletingLastPathComponent()
        let url = repository.appendingPathComponent("testsets/capture_golden.json")
        return try JSONDecoder().decode(Corpus.self, from: Data(contentsOf: url))
    }

    func testGoldenCorpusMetricsAndNoLeaksOffMainActor() async throws {
        let corpus = try loadCorpus()
        let result = await Task.detached {
            self.evaluate(corpus.cases)
        }.value
        let floors = corpus.floors.swift

        XCTAssertEqual(corpus.cases.filter { $0.secrets.isEmpty }.count, floors.negatives)
        XCTAssertGreaterThanOrEqual(result.found, floors.found, "missing: \(result.missed)")
        XCTAssertGreaterThanOrEqual(result.primary, floors.primary, "wrong primary: \(result.wrongPrimary)")
        XCTAssertGreaterThanOrEqual(result.template, floors.template, "wrong template: \(result.wrongTemplate)")
        XCTAssertGreaterThanOrEqual(result.secondary, floors.secondary, "secondary misses: \(result.secondaryMissed)")
        XCTAssertEqual(result.secondaryCases, floors.secondaryCases)
        XCTAssertEqual(result.falsePositives, floors.falsePositives, "false positives: \(result.falsePositiveIDs)")
        XCTAssertEqual(result.leaks, floors.leaks, "leaks: \(result.leaked)")
    }

    func testGoldenCorpusIsByteIdenticalAcrossTwentyRunsOffMainActor() async throws {
        let corpus = try loadCorpus()
        let runs = corpus.floors.swift.determinismRuns
        XCTAssertEqual(runs, 20)

        let unstable = await Task.detached { () -> [String] in
            var unstable: [String] = []
            for item in corpus.cases {
                let first = self.canonicalCapture(CaptureParser.parse(item.text))
                for _ in 1 ..< runs where self.canonicalCapture(CaptureParser.parse(item.text)) != first {
                    unstable.append(item.id)
                    break
                }
            }
            return unstable
        }.value
        XCTAssertTrue(unstable.isEmpty, "non-deterministic cases: \(unstable)")
    }

    private nonisolated func evaluate(_ cases: [Case]) -> Metrics {
        var result = Metrics()
        for item in cases {
            let capture = CaptureParser.parse(item.text)
            if item.secrets.isEmpty {
                result.negatives += 1
                if capture.primarySecret != nil {
                    result.falsePositives += 1
                    result.falsePositiveIDs.append(item.id)
                }
                continue
            }

            if capture.primarySecret != nil {
                result.found += 1
            } else {
                result.missed.append(item.id)
            }
            if capture.primarySecret == item.secrets[0] {
                result.primary += 1
            } else {
                result.wrongPrimary.append(item.id)
            }
            if capture.templateType == item.template {
                result.template += 1
            } else {
                result.wrongTemplate.append("\(item.id)(\(capture.templateType)≠\(item.template))")
            }

            let captured = Set(capture.secrets.map(\.value))
            if item.secrets.count > 1 {
                result.secondaryCases += 1
                if item.secrets.dropFirst().allSatisfy(captured.contains) {
                    result.secondary += 1
                } else {
                    result.secondaryMissed.append(item.id)
                }
            }

            let stored = capture.fields.filter { !$0.hidden }.map { ("field:\($0.key)", $0.value) }
                + [("name", capture.name), ("notes", capture.notes), ("excerpt", capture.excerpt ?? "")]
            for secret in item.secrets {
                for form in encodedForms(secret) where !form.isEmpty {
                    for (location, value) in stored where value.contains(form) {
                        result.leaks += 1
                        result.leaked.append("\(item.id):\(location)")
                    }
                }
            }
        }
        return result
    }

    private nonisolated func encodedForms(_ secret: String) -> Set<String> {
        Set([
            secret,
            secret.addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? secret,
            secret.removingPercentEncoding ?? secret,
        ])
    }

    /// A stable, complete representation of the structured output. Unlike a
    /// hash, it also makes a failure reproducible without relying on Hasher's
    /// per-process seed.
    private nonisolated func canonicalCapture(_ capture: ParsedCapture) -> String {
        var parts = [
            "template=\(capture.templateType)",
            "cluster=\(capture.clusterDecision.clusterID.rawValue)",
            "confidence=\(capture.clusterDecision.confidence)",
            "reasons=\(capture.clusterDecision.reasons.joined(separator: "\u{1F}"))",
            "name=\(capture.name)",
            "notes=\(capture.notes)",
            "excerpt=\(capture.excerpt ?? "<nil>")",
        ]
        for signal in capture.signals {
            parts.append("signal=\(signal.category.rawValue)\u{1F}\(signal.name)\u{1F}\(signal.value)\u{1F}\(signal.normalizedValue)")
        }
        for secret in capture.secrets {
            parts.append("secret=\(secret.key)\u{1F}\(secret.rawKey)\u{1F}\(secret.value)\u{1F}\(String(describing: secret.source))\u{1F}\(secret.tier)\u{1F}\(secret.order)")
        }
        for field in capture.fields {
            parts.append("field=\(field.key)\u{1F}\(field.label)\u{1F}\(field.value)\u{1F}\(field.valueType)\u{1F}\(field.semantic ?? "<nil>")\u{1F}\(field.hidden)\u{1F}\(field.section ?? "<nil>")\u{1F}\(field.order)")
        }
        return parts.joined(separator: "\u{1E}")
    }
}

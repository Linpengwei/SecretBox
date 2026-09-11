#if canImport(AppKit)
import AppKit
import SwiftUI
import XCTest

/// Minimal in-repo replacement for pointfree/swift-snapshot-testing (GitHub is
/// unreachable from the current build environment, so the package cannot be
/// resolved). Renders a SwiftUI view offscreen, compares it against a committed
/// baseline PNG in `__Snapshots__/<TestName>/`, and auto-records a baseline the
/// first time a snapshot name is seen.
///
/// Usage:
/// ```swift
/// assertViewSnapshot(of: LoginView(model: model), size: 420x520)
/// assertViewSnapshot(of: view, size: 420x520, appearance: .dark, named: "dark")
/// ```
/// When a baseline is missing, the snapshot is recorded and the test FAILS once;
/// rerun the suite and it will compare against the new baseline.
enum SnapshotLite {
    static var precision: Double { 0.98 }

    static func render<V: View>(_ view: V, size: CGSize, appearance: NSAppearance? = nil) -> NSImage {
        let hosting = NSHostingView(rootView: view.frame(width: size.width, height: size.height))
        hosting.frame = NSRect(origin: .zero, size: size)
        if let appearance {
            hosting.appearance = appearance
        }
        hosting.layoutSubtreeIfNeeded()

        let representation = hosting.bitmapImageRepForCachingDisplay(in: hosting.bounds)!
        hosting.cacheDisplay(in: hosting.bounds, to: representation)
        let image = NSImage(size: size)
        image.addRepresentation(representation)
        return image
    }

    static func pngData(_ image: NSImage) -> Data? {
        guard let tiff = image.tiffRepresentation,
              let rep = NSBitmapImageRep(data: tiff) else { return nil }
        return rep.representation(using: .png, properties: [:])
    }

    static func baselineURL(testName: String, named: String) -> URL {
        let testsDir = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        return testsDir
            .appendingPathComponent("__Snapshots__")
            .appendingPathComponent(testName)
            .appendingPathComponent("\(named).png")
    }

    /// Returns fraction (0...1) of pixels that differ beyond a small tolerance.
    static func fractionOfDifferingPixels(_ lhs: NSImage, _ rhs: NSImage) -> Double? {
        guard let lhsRep = lhs.tiffRepresentation.flatMap(NSBitmapImageRep.init(data:)),
              let rhsRep = rhs.tiffRepresentation.flatMap(NSBitmapImageRep.init(data:)),
              lhsRep.pixelsWide == rhsRep.pixelsWide,
              lhsRep.pixelsHigh == rhsRep.pixelsHigh else { return nil }

        var differing = 0
        let total = lhsRep.pixelsWide * lhsRep.pixelsHigh
        for y in 0..<lhsRep.pixelsHigh {
            for x in 0..<lhsRep.pixelsWide {
                guard let a = lhsRep.colorAt(x: x, y: y), let b = rhsRep.colorAt(x: x, y: y) else {
                    differing += 1
                    continue
                }
                if abs(a.redComponent - b.redComponent) > 0.02
                    || abs(a.greenComponent - b.greenComponent) > 0.02
                    || abs(a.blueComponent - b.blueComponent) > 0.02
                    || abs(a.alphaComponent - b.alphaComponent) > 0.02 {
                    differing += 1
                }
            }
        }
        return Double(differing) / Double(total)
    }
}

extension XCTestCase {
    func assertViewSnapshot<V: View>(
        of view: V,
        size: CGSize,
        appearance: NSAppearance? = nil,
        named: String,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        let testName = String(describing: type(of: self))
        let rendered = SnapshotLite.render(view, size: size, appearance: appearance)
        let baselineURL = SnapshotLite.baselineURL(testName: testName, named: named)

        guard let baseline = NSImage(contentsOf: baselineURL) else {
            let data = SnapshotLite.pngData(rendered)
            try? data?.write(to: baselineURL)
            XCTFail(
                "No baseline for \"\(named)\"; recorded a new one at \(baselineURL.path). Re-run the tests.",
                file: file,
                line: line
            )
            return
        }

        guard let differing = SnapshotLite.fractionOfDifferingPixels(rendered, baseline) else {
            XCTFail("Snapshot \"\(named)\" could not be compared (size mismatch).", file: file, line: line)
            return
        }

        let tolerance = 1 - SnapshotLite.precision
        if differing > tolerance {
            let data = SnapshotLite.pngData(rendered)
            let failureURL = baselineURL.deletingLastPathComponent()
                .appendingPathComponent("\(named)-failed.png")
            try? data?.write(to: failureURL)
            XCTFail(
                "Snapshot \"\(named)\" does not match baseline (\(String(format: "%.2f", differing * 100))% pixels differ). Rendered image saved to \(failureURL.path).",
                file: file,
                line: line
            )
        }
    }
}
#endif

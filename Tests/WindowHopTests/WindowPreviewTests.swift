import AppKit
import XCTest
@testable import WindowHop

final class WindowPreviewTests: XCTestCase {
    private func window(_ title: String, id: UUID = UUID(), minimized: Bool = false) -> WindowRecord {
        WindowRecord(id: id, pid: 1, element: AXUIElementCreateApplication(1),
                     appName: "Fixture", title: title, minimized: minimized, hidden: false,
                     icon: nil, lastUsed: 0)
    }

    func testStaleThumbnailDisplaysDuringRefreshAndTitleChangesDiscardIt() {
        let original = window("Original")
        let image = NSImage(size: NSSize(width: 1, height: 1))
        let now = Date()
        var cache = WindowPreviewCache()
        cache.store(image, for: original, at: now)
        XCTAssertTrue(cache.previews(for: [original], at: now.addingTimeInterval(10)).pending.isEmpty)
        let stale = cache.previews(for: [original], at: now.addingTimeInterval(11))
        guard case let .image(displayed) = stale.display[original.id] else { return XCTFail("Lost stale preview") }
        XCTAssertTrue(displayed === image)
        XCTAssertEqual(stale.pending.map(\.id), [original.id])

        let minimized = window("Original", id: original.id, minimized: true)
        let resting = cache.previews(for: [minimized], at: now.addingTimeInterval(60))
        XCTAssertNotNil(resting.display[minimized.id])
        XCTAssertTrue(resting.pending.isEmpty)

        let renamed = window("Renamed", id: original.id)
        XCTAssertNil(cache.previews(for: [renamed]).display[renamed.id])
        cache.reconcile([renamed])
        XCTAssertNil(cache.previews(for: [original]).display[original.id])
    }

    func testCacheEvictsOldestAndDropsClosedWindows() {
        let windows = (0..<25).map { window(String($0)) }
        var cache = WindowPreviewCache()
        let now = Date()
        let image = NSImage(size: NSSize(width: 1, height: 1))
        for (index, window) in windows.enumerated() {
            cache.store(image, for: window, at: now.addingTimeInterval(Double(index)))
        }
        let previews = cache.previews(for: windows, at: now.addingTimeInterval(25))
        XCTAssertEqual(previews.display.count, 24)
        XCTAssertNil(previews.display[windows[0].id])
        cache.reconcile([])
        XCTAssertTrue(cache.previews(for: windows).display.isEmpty)
    }

    func testCaptureMatchesKnownWindowNumberAndSkipsAmbiguousTitles() {
        var record = window("Document")
        let candidates: [SystemWindowPreviews.Candidate] = [(10, "Document"), (11, "Document")]
        XCTAssertNil(SystemWindowPreviews.matchingID(for: record, in: candidates))
        record.windowNumber = 11
        XCTAssertEqual(SystemWindowPreviews.matchingID(for: record, in: candidates), 11)
        record.windowNumber = 12
        XCTAssertNil(SystemWindowPreviews.matchingID(for: record, in: candidates))
    }

    private actor CaptureProbe {
        let started: XCTestExpectation
        private(set) var visits: [UUID] = []
        private var continuation: CheckedContinuation<Void, Never>?
        init(_ started: XCTestExpectation) { self.started = started }

        func capture(_ window: WindowRecord) async -> NSImage? {
            XCTAssertNil(continuation, "Two screenshots overlapped")
            visits.append(window.id)
            if visits.count == 1 {
                await withCheckedContinuation {
                    continuation = $0
                    started.fulfill()
                }
            }
            return nil
        }

        func resume() {
            continuation?.resume()
            continuation = nil
        }
    }

    @MainActor func testLatestHighlightIsNextWithoutRepeatingCaptures() async {
        let started = expectation(description: "First capture in flight")
        let done = expectation(description: "Each capture delivered")
        done.expectedFulfillmentCount = 4
        let probe = CaptureProbe(started)
        let loader = WindowPreviewLoader { { await probe.capture($0) } }
        let windows = (0..<4).map { window(String($0)) }
        loader.start(windows, selected: windows[1].id) { _, image in
            XCTAssertNil(image)
            done.fulfill()
        }
        await fulfillment(of: [started], timeout: 2)
        loader.selected = windows[2].id
        loader.selected = windows[3].id
        await probe.resume()
        await fulfillment(of: [done], timeout: 2)
        let visits = await probe.visits
        XCTAssertEqual(visits, [1, 3, 0, 2].map { windows[$0].id })
    }

    @MainActor func testRapidReopenDropsOldResultAndSkipsCanceledPass() async {
        let started = expectation(description: "Old capture in flight")
        let done = expectation(description: "New picker receives its result")
        let probe = CaptureProbe(started)
        let loader = WindowPreviewLoader { { await probe.capture($0) } }
        let windows = (0..<3).map { window(String($0)) }
        loader.start(windows, selected: windows[0].id) { _, _ in XCTFail("Published after dismissal") }
        await fulfillment(of: [started], timeout: 2)
        loader.cancel()
        loader.start([windows[1]], selected: nil) { _, _ in XCTFail("Published superseded result") }
        loader.start([windows[2]], selected: nil) { _, _ in done.fulfill() }
        await probe.resume()
        await fulfillment(of: [done], timeout: 2)
        let visits = await probe.visits
        XCTAssertEqual(visits, [windows[0].id, windows[2].id])
    }
}

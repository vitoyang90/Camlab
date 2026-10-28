import Foundation
import Testing
@testable import Camlab

struct PreviewPresentationTests {
    @Test(arguments: [Double(0), -1, .nan, .infinity])
    func skippedFramesDoNotFinishStartup(time: Double) {
        let tracker = PreviewPresentationTracker()
        let id = UUID()
        tracker.begin(id)
        #expect(!tracker.record(id, presentedTime: time))
        #expect(tracker.shouldObserve(id))
        #expect(tracker.record(id, presentedTime: 100))
    }

    @Test func realPresentationReportsOnlyOnce() {
        let tracker = PreviewPresentationTracker()
        let id = UUID()
        tracker.begin(id)
        #expect(tracker.record(id, presentedTime: 100))
        tracker.begin(id)
        #expect(!tracker.shouldObserve(id))
        #expect(!tracker.record(id, presentedTime: 101))
    }

    @Test func staleCallbacksCannotFinishNewStartup() {
        let tracker = PreviewPresentationTracker()
        let old = UUID(), current = UUID()
        tracker.begin(old)
        tracker.begin(current)
        #expect(!tracker.record(old, presentedTime: 100))
        #expect(tracker.shouldObserve(current))
        #expect(tracker.record(current, presentedTime: 101))
    }

    @Test func concurrentCallbacksReportOnlyOnce() async {
        let tracker = PreviewPresentationTracker()
        let id = UUID()
        tracker.begin(id)
        let reports = await withTaskGroup(of: Bool.self) { group in
            for _ in 0..<100 {
                group.addTask { tracker.record(id, presentedTime: 100) }
            }
            var count = 0
            for await reported in group { if reported { count += 1 } }
            return count
        }
        #expect(reports == 1)
    }
}

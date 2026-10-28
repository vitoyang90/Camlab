import SwiftUI
import Testing
@testable import Camlab

struct PreviewLifecycleTests {
    @MainActor @Test func rotationDuringStartupKeepsTheSameMetalView() async throws {
        let host = UIHostingController(rootView: ContentView())
        let scene = try #require(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let window = UIWindow(windowScene: scene)
        window.frame = CGRect(x: 0, y: 0, width: 390, height: 844)
        window.rootViewController = host
        window.isHidden = false
        defer { window.isHidden = true; window.rootViewController = nil }

        func resize(_ size: CGSize) async throws {
            window.frame.size = size
            host.view.frame = window.bounds
            host.view.setNeedsLayout()
            host.view.layoutIfNeeded()
            try await Task.sleep(for: .milliseconds(150))
            host.view.layoutIfNeeded()
        }
        func previews(in view: UIView) -> [PreviewView] {
            (view as? PreviewView).map { [$0] } ?? view.subviews.flatMap { previews(in: $0) }
        }

        try await resize(CGSize(width: 390, height: 844))
        let preview = try #require(previews(in: host.view).first)
        let portraitSize = preview.bounds.size
        for _ in 0..<3 {
            try await resize(CGSize(width: 844, height: 390))
            let landscapePreviews = previews(in: host.view)
            #expect(landscapePreviews.count == 1)
            #expect(landscapePreviews.first === preview)
            #expect(preview.bounds.width > preview.bounds.height)
            try await resize(CGSize(width: 390, height: 844))
            #expect(previews(in: host.view).first === preview)
            #expect(preview.bounds.size == portraitSize)
        }
    }
}

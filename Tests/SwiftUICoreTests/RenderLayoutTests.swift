import Foundation
import Testing
@testable import _SwiftUICore

/// `RenderContent` has a layout fixed at compile time, so the classes storing it (`RenderNode`,
/// `NodeAnimation`) get constant field offsets. With a payload holding a resilient Foundation type
/// (`URL`, `Date`), its size is known only at run time, and those classes' field offsets come from
/// globals the runtime fills in on first use: the AppKit catalog's first `NodeAnimation` was stored
/// through one still zero, which overwrote its class pointer (`Renderer.tick` crashed releasing it).
@Suite
struct RenderLayoutTests {
    @Test func renderContentHasAFixedLayout() {
        #expect(!needsRuntimeLayout(RenderContent.self))
        #expect(!needsRuntimeLayout(NodeAnimation.Layer.self))
        #expect(!needsRuntimeLayout(TransitionAnimation.self))
        #if canImport(Darwin)
        // The probe sees a runtime layout where there is one (`ResolvedText` holds a `URL`).
        #expect(needsRuntimeLayout(ResolvedText.self))
        #endif
    }

    /// Whether the runtime completes a struct's or enum's metadata (its layout) on first use: the
    /// singleton metadata initialization kind of its type descriptor (`TypeContextDescriptorFlags`,
    /// bits 16–17 of the context descriptor's flags).
    func needsRuntimeLayout(_ type: Any.Type) -> Bool {
        let metadata = unsafeBitCast(type, to: UnsafeRawPointer.self)
        let descriptor = metadata.load(fromByteOffset: MemoryLayout<UInt>.size, as: UnsafeRawPointer.self)
        return (descriptor.load(as: UInt32.self) >> 16) & 0x3 == 1
    }
}

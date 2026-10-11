import Testing
@testable import SwiftUIGraph

@MainActor
struct AttributeGraphTests {
    let graph = AttributeGraph()
    var root: Subgraph { Subgraph(graph: graph) }

    @Test func computedAttributeRecomputesOnlyWhenInputChanges() {
        let sg = Subgraph(graph: graph)
        let a = Attribute(sg, value: 1)
        var runs = 0
        let b = Attribute(sg) { () -> Int in runs += 1; return a.value * 2 }
        #expect(b.value == 2)
        #expect(b.value == 2)
        #expect(runs == 1)
        a.setValue(1) // equal: no invalidation
        #expect(b.value == 2)
        #expect(runs == 1)
        a.setValue(5)
        #expect(b.value == 10)
        #expect(runs == 2)
    }

    @Test func equalityCutoffStopsDownstreamRecomputation() {
        let sg = Subgraph(graph: graph)
        let a = Attribute(sg, value: 3)
        var parityRuns = 0, labelRuns = 0
        let isEven = Attribute(sg) { () -> Bool in parityRuns += 1; return a.value % 2 == 0 }
        let label = Attribute(sg) { () -> String in labelRuns += 1; return isEven.value ? "even" : "odd" }
        #expect(label.value == "odd")
        a.setValue(5)
        #expect(label.value == "odd")
        #expect(parityRuns == 2)
        #expect(labelRuns == 1) // cut off: isEven did not change
    }

    @Test func dynamicDependenciesAreDropped() {
        let sg = Subgraph(graph: graph)
        let flag = Attribute(sg, value: true)
        let x = Attribute(sg, value: 1)
        let y = Attribute(sg, value: 100)
        var runs = 0
        let r = Attribute(sg) { () -> Int in runs += 1; return flag.value ? x.value : y.value }
        #expect(r.value == 1)
        flag.setValue(false)
        #expect(r.value == 100)
        x.setValue(2) // no longer a dependency
        #expect(!r.isDirty)
        #expect(r.value == 100)
        #expect(runs == 2)
    }

    @Test func eagerAttributesUpdateInOrder() {
        let sg = Subgraph(graph: graph)
        let source = Attribute(sg, value: 0)
        var log: [String] = []
        let deep = Attribute(sg) { () -> Int in log.append("deep"); return source.value }
        deep.order = 5
        deep.isEager = true
        let shallow = Attribute(sg) { () -> Int in log.append("shallow"); return source.value }
        shallow.order = 1
        shallow.isEager = true
        graph.update()
        log.removeAll()
        source.setValue(1)
        graph.update()
        #expect(log == ["shallow", "deep"])
    }

    @Test func dirtyMarksDuringOwnComputationAreKept() {
        // An onChange that invalidates an upstream attribute feeding back into the observer
        // must not leave the observer clean while its input is dirty.
        let sg = Subgraph(graph: graph)
        let source = Attribute(sg, value: 0)
        var external = 0
        let upstream = Attribute(sg) { () -> Int in external + source.value }
        let middle = Attribute(sg) { upstream.value }
        let observer = Attribute(sg) { middle.value }
        observer.isEager = true
        var fired = 0
        observer.onChange = { _ in
            fired += 1
            if fired == 1 { upstream.invalidate() }
        }
        graph.update()
        graph.update()
        #expect(!middle.isDirty || observer.isDirty)
        source.setValue(5)
        graph.update()
        #expect(observer.peekValue == 5)
    }

    @Test func externalInvalidationForcesRecompute() {
        let sg = Subgraph(graph: graph)
        var external = 1
        var runs = 0
        let r = Attribute(sg) { () -> Int in runs += 1; return external }
        #expect(r.value == 1)
        external = 2
        r.invalidate()
        #expect(r.value == 2)
        #expect(runs == 2)
    }

    @Test func destroyingSubgraphRemovesEdges() {
        let rootGraph = Subgraph(graph: graph)
        let source = Attribute(rootGraph, value: 1)
        let child = rootGraph.makeChild()
        var cleaned = false
        child.onDestroy { cleaned = true }
        let derived = Attribute(child) { source.value + 1 }
        #expect(derived.value == 2)
        #expect(source.outputs.count == 1)
        child.destroy()
        #expect(cleaned)
        #expect(source.outputs.isEmpty)
        #expect(derived.isDestroyed)
        #expect(derived.peekValue == 2)
    }

    @Test func existentialFieldComparison() {
        // A struct holding a non-class protocol existential: comparing must open the payload, not
        // re-box the existential (that recursed until the stack overflowed).
        struct Handler: ComparisonTestProtocol { var value: Int }
        struct Holder { var handler: any ComparisonTestProtocol }
        #expect(GraphComparison.isIdentical(Holder(handler: Handler(value: 1)), Holder(handler: Handler(value: 1))))
        #expect(!GraphComparison.isIdentical(Holder(handler: Handler(value: 1)), Holder(handler: Handler(value: 2))))
    }

    @Test func structuralComparison() {
        struct Inner { var a: Int; var s: String }
        struct V { var x: Int; var inner: Inner; var object: AnyObject?; var f: () -> Void }
        final class Box {}
        let box = Box()
        let f: () -> Void = {}
        let v1 = V(x: 1, inner: Inner(a: 1, s: "a"), object: box, f: f)
        var v2 = v1
        #expect(GraphComparison.isIdentical(v1, v2))
        v2.inner.s = "b"
        #expect(!GraphComparison.isIdentical(v1, v2))
        v2 = v1
        v2.object = Box()
        #expect(!GraphComparison.isIdentical(v1, v2))
        let captured = 5
        v2 = v1
        v2.f = { _ = captured }
        #expect(!GraphComparison.isIdentical(v1, v2))
        let anyA: Any = Inner(a: 1, s: "x")
        let anyB: Any = Inner(a: 1, s: "x")
        #expect(GraphComparison.compareAny(anyA, anyB))
    }
}

protocol ComparisonTestProtocol {}

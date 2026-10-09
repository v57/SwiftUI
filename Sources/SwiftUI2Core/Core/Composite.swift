import Foundation
#if canImport(CoreGraphics)
import CoreGraphics
#endif
import Observation

/// Creates the attribute that evaluates a composite view's (or custom modifier's) body.
///
/// The rule:
///  1. reads the view value (dependency with structural equality cut-off — an unchanged view value
///     never re-runs body),
///  2. installs dynamic properties (State, Environment, ObservedObject, ...) whose reads register
///     fine-grained dependencies,
///  3. runs body inside `withObservationTracking`, so reading an `@Observable` property makes body
///     depend on exactly that property.
@MainActor
func makeBodyAttribute<V, Body>(
    view: Attribute<V>,
    inputs: _ViewListInputs,
    path: ViewPath,
    body makeBody: @escaping @MainActor (V) -> Body
) -> Attribute<Body> {
    let context = DynamicPropertyContext(host: inputs.host, subgraph: inputs.subgraph, environment: inputs.environment, path: path)
    let buffer = DynamicPropertyBuffer(for: V.self)
    let view = animatedIfNeeded(view, host: inputs.host, scope: inputs.animationScope, subgraph: inputs.subgraph)
    let attribute = Attribute<Body>(inputs.subgraph)
    attribute.label = "body \(path)"
    context.owner = attribute
    let tracer = inputs.host.tracer
    attribute.setRule { [unowned attribute] in
        var value = view.value
        buffer.install(into: &value, context: context)
        tracer.record(.body, path)
        return observingChanges(invalidating: attribute) { makeBody(value) }
    }
    return attribute
}

/// Runs `body` with Observation tracking; any tracked `@Observable` property change invalidates
/// `attribute` (which then re-runs on the next graph update).
@MainActor
func observingChanges<R>(invalidating attribute: AnyAttribute, _ body: () -> R) -> R {
    withObservationTracking(body, onChange: { [weak attribute] in
        invalidateOnMain(attribute)
    })
}

nonisolated func invalidateOnMain(_ attribute: AnyAttribute?) {
    guard let attribute else { return }
    if Thread.isMainThread {
        MainActor.assumeIsolated { attribute.invalidate() }
    } else {
        DispatchQueue.main.async { attribute.invalidate() }
    }
}

/// An attribute whose rule runs with Observation tracking (for rules that call user closures or
/// read bindings that may be backed by `@Observable` models).
@MainActor
func makeObservedAttribute<T>(_ subgraph: Subgraph, of type: T.Type = T.self, isEqual: @escaping (T, T) -> Bool = GraphComparison.isIdentical, _ rule: @escaping @MainActor () -> T) -> Attribute<T> {
    let attribute = Attribute<T>(subgraph, isEqual: isEqual)
    attribute.setRule { [unowned attribute] in observingChanges(invalidating: attribute, rule) }
    return attribute
}

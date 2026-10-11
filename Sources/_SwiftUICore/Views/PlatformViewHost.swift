import Foundation
#if canImport(CoreGraphics)
import CoreGraphics
#endif

/// A native view embedded in the hierarchy (`NSViewRepresentable`, `UIViewRepresentable`, a GTK
/// widget, ...). Backend modules implement this protocol for their platform's representables.
@MainActor
public protocol _PlatformViewProvider: AnyObject {
    /// The native view object (NSView, GtkWidget, ...). The backend embeds it as is.
    var platformView: AnyObject { get }
    /// Size for a proposal (defaults to intrinsic content size / flexible).
    func sizeThatFits(_ proposal: ProposedViewSize) -> CGSize
    /// Called once when the view leaves the hierarchy.
    func dismantle()
}

/// Identity + version of a hosted native view (content changes when the representable updated).
public struct PlatformViewToken: Equatable, @unchecked Sendable {
    public let object: AnyObject
    public let version: Int

    public static func == (lhs: PlatformViewToken, rhs: PlatformViewToken) -> Bool {
        lhs.object === rhs.object && lhs.version == rhs.version
    }
}

@MainActor
private final class PlatformViewState {
    var provider: _PlatformViewProvider?
    var version = 0
}

final class PlatformViewComputer: LayoutComputer {
    let provider: _PlatformViewProvider
    let version: Int

    init(provider: _PlatformViewProvider, version: Int, path: ViewPath, tracer: UpdateTracer) {
        self.provider = provider
        self.version = version
        super.init(path: path, tracer: tracer)
    }

    override func computeSize(_ proposal: ProposedViewSize) -> CGSize { provider.sizeThatFits(proposal) }

    override func isEquivalent(to other: LayoutComputer) -> Bool {
        guard let other = other as? PlatformViewComputer else { return false }
        return other.provider === provider && other.version == version
    }
}

/// Builds the graph for a representable view: `make` runs once per identity, `update` whenever the
/// view value or the environment it reads changes.
@MainActor
public func _makePlatformViewHost<V>(
    view: _GraphValue<V>,
    inputs: _ViewInputs,
    make: @escaping @MainActor (V, EnvironmentValues, Transaction) -> _PlatformViewProvider,
    update: @escaping @MainActor (_PlatformViewProvider, V, EnvironmentValues, Transaction) -> Void
) -> _ViewOutputs {
    let inputs = inputs.with(path: typeName(V.self))
    let state = PlatformViewState()
    let environment = inputs.environment
    let host = inputs.host
    let scope = inputs.animationScope
    let content = Attribute<RenderContent>(inputs.subgraph, isEqual: { $0 == $1 }) {
        let value = view.attribute.value
        let env = environment.value
        let transaction = scope?.resolve(host.currentTransaction) ?? host.currentTransaction
        AnyAttribute.withoutDependencies {
            if let provider = state.provider {
                update(provider, value, env, transaction)
            } else {
                let provider = make(value, env, transaction)
                state.provider = provider
                update(provider, value, env, transaction)
            }
        }
        state.version += 1
        return .platformView(PlatformViewToken(object: state.provider!.platformView, version: state.version))
    }
    inputs.subgraph.onDestroy {
        state.provider?.dismantle()
        state.provider = nil
    }
    inputs.makePlatformNode(content: content)
    let tracer = inputs.tracer
    let path = inputs.path
    let layout = inputs.makeLayoutAttribute {
        _ = content.value
        return PlatformViewComputer(provider: state.provider!, version: state.version, path: path, tracer: tracer)
    }
    return _ViewOutputs(layout: layout)
}


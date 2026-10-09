import Foundation
#if canImport(CoreGraphics)
import CoreGraphics
#endif

extension Color: View {
    public var body: Never { primitiveBody(Self.self) }

    public static func _makeView(view: _GraphValue<Color>, inputs: _ViewInputs) -> _ViewOutputs {
        let inputs = inputs.with(path: "Color")
        let environment = inputs.environment
        let content = Attribute<RenderContent>(inputs.subgraph, isEqual: { $0 == $1 }) {
            .color(view.attribute.value.resolve(in: environment.value))
        }
        inputs.makePlatformNode(content: content)
        let tracer = inputs.tracer
        let path = inputs.path
        return _ViewOutputs(layout: inputs.makeLayoutAttribute { FlexibleLayoutComputer(path: path, tracer: tracer) })
    }
}

// Exercises desktop and drawing features backends must support: menu bar commands and keyboard
// shortcuts, onKeyPress, file dialogs, shadows, masks, blend modes, color filters, path clips and
// filled symbols. Plain SwiftUI (built for Windows as FeatureTourWinUI).
import SwiftUI2
import UniformTypeIdentifiers

@Observable
@MainActor
final class TourModel {
    var count = 0
    var grayscale = false
    var lastKey = "none"
    var importing = false
    var picked = "nothing yet"
}

@main
struct FeatureTourApp: App {
    @State private var model = TourModel()

    var body: some Scene {
        WindowGroup("Feature Tour") {
            TourView().environment(model)
        }
        .commands {
            CommandMenu("Tour") {
                Button("Increment") { model.count += 1 }
                    .keyboardShortcut("i", modifiers: .command)
                Toggle("Grayscale", isOn: Binding(get: { model.grayscale }, set: { model.grayscale = $0 }))
                    .keyboardShortcut("g", modifiers: [.command, .shift])
                Divider()
                Button("Reset Count") { model.count = 0 }
            }
            CommandGroup(after: .newItem) {
                Button("Import…") { model.importing = true }
                    .keyboardShortcut("o", modifiers: .command)
            }
        }
    }
}

/// A five-pointed star.
struct Star: Shape {
    func path(in rect: CGRect) -> Path {
        var path = Path()
        let center = CGPoint(x: rect.midX, y: rect.midY)
        let outer = min(rect.width, rect.height) / 2, inner = outer * 0.45
        for i in 0..<10 {
            let angle = Double(i) * .pi / 5 - .pi / 2
            let radius = i.isMultiple(of: 2) ? outer : inner
            let point = CGPoint(x: center.x + radius * cos(angle), y: center.y + radius * sin(angle))
            if i == 0 { path.move(to: point) } else { path.addLine(to: point) }
        }
        path.closeSubpath()
        return path
    }
}

struct TourView: View {
    @Environment(TourModel.self) private var model

    var body: some View {
        @Bindable var model = model
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                Text("Feature Tour").font(.title)

                GroupBox("Keyboard") {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Count: \(model.count) · Ctrl+I or Tour ▸ Increment")
                        Text("Last key: \(model.lastKey)")
                        HStack {
                            Button("Add 10") { model.count += 10 }.keyboardShortcut("k", modifiers: .command)
                            Button("Import…") { model.importing = true }
                            Text("Picked: \(model.picked)").lineLimit(1)
                        }
                    }
                }

                GroupBox("Drawing") {
                    HStack(spacing: 24) {
                        RoundedRectangle(cornerRadius: 12).fill(.blue)
                            .frame(width: 70, height: 70)
                            .shadow(color: .black.opacity(0.4), radius: 6, x: 4, y: 4)
                        HStack { Image(systemName: "star.fill"); Text("Group") }
                            .padding(10).background(.white, in: Capsule())
                            .shadow(color: .black.opacity(0.35), radius: 5, y: 3)
                        LinearGradient(colors: [.red, .orange, .purple], startPoint: .leading, endPoint: .trailing)
                            .frame(width: 120, height: 50)
                            .mask { Text("MASK").font(.system(size: 36, weight: .black)) }
                        ZStack {
                            Circle().fill(.red).frame(width: 50, height: 50).offset(x: -12)
                            Circle().fill(.blue).frame(width: 50, height: 50).offset(x: 12).blendMode(.multiply)
                        }
                    }
                }

                GroupBox("Filters, clips, symbols") {
                    HStack(spacing: 24) {
                        Color.orange.frame(width: 70, height: 70).clipShape(Star())
                        Color.green.frame(width: 70, height: 70).clipShape(Circle())
                        Image(systemName: "photo.fill").font(.system(size: 40)).foregroundStyle(.pink)
                            .grayscale(model.grayscale ? 1 : 0)
                        Image(systemName: "sun.max.fill").font(.system(size: 40)).foregroundStyle(.yellow)
                            .hueRotation(.degrees(120))
                        Image(systemName: "heart").font(.system(size: 40)).foregroundStyle(.red)
                        Image(systemName: "heart.fill").font(.system(size: 40)).foregroundStyle(.red)
                    }
                }
            }
            .padding(24)
        }
        .onKeyPress { press in
            model.lastKey = press.characters.isEmpty ? "\(press.key.character)" : press.characters
            return .ignored
        }
        .fileImporter(isPresented: $model.importing, allowedContentTypes: [.plainText, .image]) { result in
            switch result {
            case .success(let url): model.picked = url.lastPathComponent
            case .failure(let error): model.picked = "error: \(error.localizedDescription)"
            }
        }
    }
}

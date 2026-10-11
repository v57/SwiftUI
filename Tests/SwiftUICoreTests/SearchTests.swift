import Foundation
import Testing
@testable import _SwiftUICore
import SwiftUIHeadless

@MainActor
@Suite(.serialized)
struct SearchTests {
    @Test func suggestionsCompleteTheSearchText() {
        struct Screen: View {
            @State var query = ""
            var body: some View {
                List { Text("results for \(query)") }
                    .searchable(text: $query)
                    .searchSuggestions {
                        Text("Apples").searchCompletion("apple")
                        Text("Pears").searchCompletion("pear")
                    }
            }
        }
        let host = TestHost(Screen())
        #expect(!host.texts.contains("Apples"))
        host.type("ap")
        host.flush()
        #expect(host.texts.contains("Apples"))
        host.tap("Apples")
        host.finishAnimations()
        #expect(host.texts.contains("results for apple"))
        #expect(!host.texts.contains("Apples"))
    }

    @Test func scopesAppearWhileSearchingAndIsSearchingIsSet() {
        struct Reader: View {
            @Environment(\.isSearching) var isSearching
            @Environment(\.dismissSearch) var dismissSearch
            var body: some View {
                VStack {
                    Text(isSearching ? "searching" : "idle")
                    Button("Done") { dismissSearch() }
                }
            }
        }
        struct Screen: View {
            @State var query = ""
            @State var scope = 0
            var body: some View {
                Reader()
                    .searchable(text: $query)
                    .searchScopes($scope) {
                        Text("All").tag(0)
                        Text("Mine").tag(1)
                    }
            }
        }
        let host = TestHost(Screen())
        #expect(host.texts.contains("idle") && !host.texts.contains("Mine"))
        host.type("x")
        #expect(host.texts.contains("searching") && host.texts.contains("Mine"))
        host.tap("Done")
        #expect(host.texts.contains("idle"))
    }

    @Test func textInputBehaviorReachesTheField() {
        struct Screen: View {
            @State var text = ""
            var body: some View {
                VStack {
                    TextField("Plain", text: $text)
                    TextField("Name", text: $text)
                        .autocorrectionDisabled()
                        .writingToolsBehavior(.disabled)
                        .textInputFormattingControlVisibility(.visible, for: .all)
                }
            }
        }
        let host = TestHost(Screen())
        let fields: [ResolvedTextField] = host.allViews.compactMap {
            if case .textField(let field) = $0.content { return field } else { return nil }
        }
        #expect(fields.count == 2)
        #expect(!fields[0].isAutocorrectionDisabled && fields[0].writingTools == .automatic)
        #expect(fields[1].isAutocorrectionDisabled && fields[1].writingTools == .disabled && fields[1].showsFormattingControls)
    }
}

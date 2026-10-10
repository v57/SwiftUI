import Combine
import Foundation
import Testing

@Test func publishersAndSubjects() {
    var received: [Int] = []
    let subject = PassthroughSubject<Int, Never>()
    let cancellable = subject.map { $0 * 2 }.filter { $0 > 2 }.sink { received.append($0) }
    subject.send(1); subject.send(2); subject.send(3)
    #expect(received == [4, 6])
    cancellable.cancel()
    var values: [String] = []
    _ = Just("a").append("b").collect().sink { values = $0 }
    #expect(values == ["a", "b"])
}

final class Model: ObservableObject {
    @Published var count = 0
}

@Test func observableObject() {
    let model = Model()
    var changes = 0
    let c = model.objectWillChange.sink { changes += 1 }
    model.count = 5
    #expect(changes == 1)
    var seen: [Int] = []
    let d = model.$count.sink { seen.append($0) }
    model.count = 6
    #expect(seen == [5, 6])
    _ = (c, d)
}

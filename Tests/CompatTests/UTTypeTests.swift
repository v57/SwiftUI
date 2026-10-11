import Testing
import UniformTypeIdentifiers

@Test func conformance() {
    #expect(UTType.png.conforms(to: .image))
    #expect(UTType.png.conforms(to: .data))
    #expect(UTType.utf8PlainText.conforms(to: .text))
    #expect(!UTType.png.conforms(to: .text))
    #expect(UTType.folder.conforms(to: .directory))
}

@Test func tags() {
    #expect(UTType(filenameExtension: "png") == .png)
    #expect(UTType(filenameExtension: "JPG") == .jpeg)
    #expect(UTType(mimeType: "application/json") == .json)
    #expect(UTType.pdf.preferredFilenameExtension == "pdf")
    let custom = UTType(filenameExtension: "torrent")
    #expect(custom != nil && custom!.conforms(to: .data) && custom!.isDynamic)
    #expect(UTType("public.png") == .png)
    #expect(UTType("com.example.unknown") == nil)
}

@Test func exported() {
    let shell = UTType(exportedAs: "dev.example.shell")
    #expect(shell.conforms(to: .data))
    #expect(UTType("dev.example.shell") == shell)
}

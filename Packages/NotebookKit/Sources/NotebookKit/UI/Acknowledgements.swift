import SwiftUI
#if os(macOS)
import AppKit
#endif

/// Notebook's own licence and those of the code it is built with, which every copy has to carry, the App Store's too:
/// in the About window on the Mac and in Settings › Acknowledgements on iPhone and iPad.
enum Acknowledgements {
    struct Entry: Identifiable {
        let name: String
        let source: URL
        let licence: String
        let text: String
        var id: String { name }
    }

    static let notebook = """
        Copyright © 2026 Lukas Kaibel.

        Notebook is free software: its source code is at github.com/lukaskaibel/notebook, under the GNU General \
        Public License, version 3, with an additional permission for elk-swift (see the README there). It comes \
        with no warranty.
        """

    static let notebookSource = URL(string: "https://github.com/lukaskaibel/notebook")!

    static let entries = [
        Entry(name: "BeautifulMermaid", source: URL(string: "https://github.com/lukilabs/beautiful-mermaid-swift")!,
              licence: "MIT License", text: mit("Copyright (c) 2026 Craft Docs")),
        Entry(name: "elk-swift", source: URL(string: "https://github.com/lukilabs/elk-swift")!,
              licence: "Eclipse Public License 2.0", text: """
                  A Swift port of the Eclipse Layout Kernel (ELK). The original ELK source code is Copyright (c) Kiel \
                  University and others.

                  The source code of elk-swift is available under the Eclipse Public License 2.0 at \
                  github.com/lukilabs/elk-swift, and the licence at eclipse.org/legal/epl-2.0. It is provided "as is", \
                  without warranty of any kind, and its contributors are not liable for any damages arising from its use.
                  """),
        Entry(name: "SwiftMath", source: URL(string: "https://github.com/mgriebling/SwiftMath")!,
              licence: "MIT License", text: mit("Copyright (c) 2023 Computer Inspirations")),
    ]

    private static func mit(_ copyright: String) -> String {
        """
        \(copyright)

        Permission is hereby granted, free of charge, to any person obtaining a copy of this software and associated \
        documentation files (the "Software"), to deal in the Software without restriction, including without \
        limitation the rights to use, copy, modify, merge, publish, distribute, sublicense, and/or sell copies of the \
        Software, and to permit persons to whom the Software is furnished to do so, subject to the following conditions:

        The above copyright notice and this permission notice shall be included in all copies or substantial portions \
        of the Software.

        THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR IMPLIED, INCLUDING BUT NOT LIMITED \
        TO THE WARRANTIES OF MERCHANTABILITY, FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL \
        THE AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER LIABILITY, WHETHER IN AN ACTION OF \
        CONTRACT, TORT OR OTHERWISE, ARISING FROM, OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER \
        DEALINGS IN THE SOFTWARE.
        """
    }

    #if os(macOS)
    /// The credits of the About window: Notebook's licence, then each package's name, link and licence.
    static var credits: NSAttributedString {
        let paragraph = NSMutableParagraphStyle()
        paragraph.alignment = .center
        let body: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 11), .foregroundColor: NSColor.secondaryLabelColor,
                                                   .paragraphStyle: paragraph]
        let heading: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 11, weight: .semibold),
                                                      .foregroundColor: NSColor.labelColor, .paragraphStyle: paragraph]
        let credits = NSMutableAttributedString(string: notebook + "\n\n", attributes: body)
        credits.append(NSAttributedString(string: "Built with\n\n", attributes: heading))
        for entry in entries {
            credits.append(NSAttributedString(string: entry.name + "\n", attributes: heading))
            var link = body
            link[.link] = entry.source
            credits.append(NSAttributedString(string: entry.source.host()! + entry.source.path() + "\n", attributes: link))
            credits.append(NSAttributedString(string: entry.licence + "\n\n" + entry.text + "\n\n", attributes: body))
        }
        return credits
    }

    static func showAbout() {
        NSApp.orderFrontStandardAboutPanel(options: [.credits: credits])
    }
    #endif
}

#if os(iOS)
/// Settings › Acknowledgements: Notebook's licence, then each package's, with a link to its source.
struct AcknowledgementsView: View {
    var body: some View {
        List {
            Section {
                Text(Acknowledgements.notebook).font(.footnote)
                Link("Source Code", destination: Acknowledgements.notebookSource)
            } header: {
                Text("Notebook")
            }
            ForEach(Acknowledgements.entries) { entry in
                Section {
                    Text(entry.text).font(.footnote)
                    Link("Source Code", destination: entry.source)
                } header: {
                    Text(entry.name)
                } footer: {
                    Text(entry.licence)
                }
            }
        }
        .navigationTitle("Acknowledgements")
        .navigationBarTitleDisplayMode(.inline)
    }
}
#endif

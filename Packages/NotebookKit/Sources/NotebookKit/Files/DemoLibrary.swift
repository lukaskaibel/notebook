#if os(macOS)
import AppKit
#else
import UIKit
#endif
import CoreText
import Foundation
import ImageIO
import PencilKit
import UniformTypeIdentifiers

/// Sample notes and files for trying Notebook and for its screenshots and tests, written to a folder of your choice so
/// your own files are never touched: Try Sample Notes on the first screen (App Review starts there too), or in Debug
/// builds `-NotebookLibrary <folder> -NotebookDemo YES`, which also hides a folder and sets a reminder to show them.
enum DemoLibrary {
    /// Hidden from the sidebar at first, to show hiding with: the header's eye button brings them back.
    static let hiddenFolders = ["Archive"]

    /// Reminders of sample notes, to show reminders with: tomorrow morning, before the appointment.
    static func reminders(now: Date = .now) -> [(path: String, date: Date)] {
        let calendar = Calendar.current
        guard let tomorrow = calendar.date(byAdding: .day, value: 1, to: now),
              let morning = calendar.date(bySettingHour: 8, minute: 30, second: 0, of: tomorrow) else { return [] }
        return [("Personal/Questions for Dr. Weber.md", morning)]
    }

    /// To-dos' dates and times, written as they would be on the day the samples are made: something overdue, things for
    /// today and the coming days, and one at a place.
    private static func due(_ days: Int, _ hour: Int? = nil, _ minute: Int = 0, now: Date = .now) -> String {
        let calendar = Calendar.current
        let day = calendar.date(byAdding: .day, value: days, to: calendar.startOfDay(for: now)) ?? now
        let date = hour.flatMap { calendar.date(bySettingHour: $0, minute: minute, second: 0, of: day) } ?? day
        return TodoDue(date, time: hour != nil).markdown
    }

    /// A time later today, at the next half hour `hours` from now, or today without a time when that would be after
    /// `latest` (hour, minute): the to-dos due today stay under Today whenever the samples are made, also late in the
    /// evening, rather than turning overdue at a fixed hour.
    static func later(by hours: Int, latest: (Int, Int), now: Date = .now) -> String {
        let calendar = Calendar.current
        let minutes = calendar.component(.hour, from: now) * 60 + calendar.component(.minute, from: now) + hours * 60
        let at = (minutes + 29) / 30 * 30
        guard at <= latest.0 * 60 + latest.1,
              let date = calendar.date(bySettingHour: at / 60, minute: at % 60, second: 0, of: now) else {
            return TodoDue(now, time: false).markdown
        }
        return TodoDue(date, time: true).markdown
    }

    static let pharmacy = TodoPlace(name: "Pharmacy at Rosenthaler Platz", latitude: 52.529_6, longitude: 13.401_3)

    /// Earlier versions of the Kyoto trip, written on a Mac and an iPhone over the last two weeks, to show version
    /// history with, oldest first: the note as it began and the plan filling up. The newest is the note as it is.
    static func versions(now: Date = .now) -> [(path: String, text: String, date: Date, device: String)] {
        let calendar = Calendar.current
        func at(_ days: Int, _ hour: Int, _ minute: Int) -> Date {
            let day = calendar.date(byAdding: .day, value: -days, to: calendar.startOfDay(for: now)) ?? now
            return calendar.date(bySettingHour: hour, minute: minute, second: 0, of: day) ?? now
        }
        let path = "Travel/Kyoto trip.md"
        return [
            (path, """
            Five days in October. Flights are booked.

            ## Packing
            - [ ] Passport
            - [ ] Rail pass voucher

            ## Plan
            - **Day 1** Fushimi Inari

            """, at(12, 21, 14), "iPhone"),
            (path, """
            Five days in October. Flights and the ryokan are booked, everything else stays loose.

            ## Packing
            - [x] Passport
            - [ ] Rail pass voucher
            - [ ] Power adapter, type A \(due(3, now: now))

            ## Plan
            - **Day 1** Fushimi Inari at sunrise
            - **Day 2** Arashiyama: bamboo grove early

            Room details are on the [ryokan's site](https://www.example.com/ryokan). Check-in is from 3 pm.

            """, at(5, 8, 42), "Mac"),
            (path, """
            Five days in October. Flights and the ryokan are booked, everything else stays loose. Costs are in [[Budget]].

            ![](.assets/torii.png)

            ## Packing
            - [x] Passport
            - [x] Rail pass voucher
            - [ ] Power adapter, type A \(due(3, now: now))
            - [ ] Rain jacket

            ## Plan
            - **Day 1** Fushimi Inari at sunrise, before the tour groups
            - **Day 2** Arashiyama: bamboo grove early
            - **Day 3** Day trip to [[Nara]]

            Room details are on the [ryokan's site](https://www.example.com/ryokan). Check-in is ==from 3 pm==.

            """, at(2, 19, 5), "iPhone"),
            (path, """
            Five days in October. Flights and the ryokan are booked, everything else stays loose. Costs are in [[Budget]], the tickets in [[Flight tickets.pdf]].

            ![](.assets/torii.png)

            ## Packing
            - [x] Passport
            - [x] Rail pass voucher
            - [ ] Power adapter, type A \(due(3, now: now))
            - [ ] Rain jacket

            ## Plan
            - **Day 1** Fushimi Inari at sunrise, before the tour groups
            - **Day 2** Arashiyama: bamboo grove early, then along the river
            - **Day 3** Day trip to [[Nara]]

            Room details are on the [ryokan's site](https://www.example.com/ryokan). Check-in is ==from 3 pm==.

            > [!tip] Good to know
            > Get an ICOCA card at the airport. It works on every train and in most convenience stores.

            """, at(1, 10, 20), "Mac"),
        ]
    }

    /// Keeps the sample versions in the history of the sample notes at `root`, made a moment ago, and the Kyoto trip as
    /// it is now, as written on a Mac 35 minutes ago: opening it finds it the same as its newest version.
    @MainActor
    static func keepVersions(at root: URL, in history: NoteHistory = .shared) {
        let now = Date()
        for version in versions(now: now) {
            history.keep(version.text, of: root.appendingPathComponent(version.path), at: version.date, device: version.device)
        }
        history.keepFile(root.appendingPathComponent("Travel/Kyoto trip.md"), at: now.addingTimeInterval(-35 * 60), device: "Mac")
    }

    /// The sample to-dos in no note, as added in To-dos, in `folder` (`LooseTodos`), in place of any there.
    static func createLooseTodos(in folder: URL) {
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let text = "- [ ] Book a table for Saturday \(due(1))\n- [ ] Ask Mia about the bike\n"
        try? Data(text.utf8).write(to: folder.appendingPathComponent(LooseTodos.fileName))
    }

    /// Makes the sample notes in `root`, unless they are there already. Says whether it made them.
    @discardableResult
    static func create(at root: URL) -> Bool {
        let fm = FileManager.default
        if fm.fileExists(atPath: root.appendingPathComponent("Travel/Kyoto trip.md").path) { return false }
        func folder(_ path: String) -> URL {
            let url = root.appendingPathComponent(path, isDirectory: true)
            try? fm.createDirectory(at: url, withIntermediateDirectories: true)
            return url
        }
        func write(_ path: String, _ text: String) {
            try? Data(text.utf8).write(to: root.appendingPathComponent(path))
        }

        _ = folder("Archive/2025")
        _ = folder("Inbox")
        _ = folder("Personal/Cooking")
        _ = folder("Projects/Design")
        _ = folder("Travel/Photos")
        _ = folder("Travel/.assets")
        _ = folder("University/Linear algebra")
        // A few folders customized, as Customize Folder does, to show it with; the others stay plain.
        FolderIcons.write(FolderIcon(symbol: "airplane", color: .blue), to: folder("Travel"))
        FolderIcons.write(FolderIcon(symbol: "graduationcap", color: .purple), to: folder("University"))
        FolderIcons.write(FolderIcon(symbol: "fork.knife", color: .orange), to: folder("Personal/Cooking"))
        FolderIcons.write(FolderIcon(emoji: "🎨"), to: folder("Projects/Design"))

        write("Archive/2025/Old apartment.md", "# Handover\n\n- [x] Meter readings\n- [x] Keys returned\n- [ ] Deposit back\n")
        write("Inbox/Gift ideas.md", "- [ ] Book for Mia: *The Remains of the Day*\n- [ ] Good olive oil\n- [x] Concert tickets\n")
        write("Inbox/Errands.md", """
        Small things for this week, each with when (or where) it should come up.

        - [ ] Return the library books \(due(-1))
        - [ ] Pick up the dry cleaning \(later(by: 2, latest: (23, 0)))
            - The ticket is in the blue jacket
            - Two shirts and the grey coat
        - [ ] Buy plasters \(pharmacy.markdown)
        - [/] Renew the passport \(due(24))
            - [x] Two photos from the booth at the station
            - [ ] Find the old passport
            - €70, by card at the town hall
        - [ ] Water the plants 🔁 every week \(due(0))
        - [x] Pay the electricity bill
        - [-] Sell the old bike

        """)
        write("Inbox/Shared link.md", "https://example.com/an-article-worth-reading\n\nRead this on the train.\n")

        write("Travel/Kyoto trip.md", """
        Five days in October. Flights and the ryokan are booked, everything else stays loose. Costs are in [[Budget]], the tickets in [[Flight tickets.pdf]].

        ![](.assets/torii.png)

        ## Packing
        - [x] Passport
        - [x] Rail pass voucher
        - [ ] Power adapter, type A \(due(3))
        - [ ] Rain jacket

        ## Plan
        - **Day 1** Fushimi Inari at sunrise, before the tour groups
        - **Day 2** Arashiyama: bamboo grove early, then along the river
        - **Day 3** Day trip to [[Nara]]

        Room details are on the [ryokan's site](https://www.example.com/ryokan). Check-in is ==from 3 pm==, dinner at 7.

        > [!tip] Good to know
        > Get an ICOCA card at the airport. It works on every train and in most convenience stores.

        | Day | Area | Note |
        | --- | --- | --- |
        | 1 | Fushimi | Early start |
        | 2 | Arashiyama | Bamboo grove |
        | 3 | Nara | Deer park |
        | 4 | Gion | Evening walk |

        ![[Flight tickets.pdf]]

        """)
        write("Travel/Getting to the ryokan.md", """
        From Kyoto Station it's twenty minutes on foot: along the river, over the second bridge, then up the lane to the ryokan.

        ![Drawing](.assets/Getting%20to%20the%20ryokan%20drawing.png)

        - [ ] Send the map to Mia \(later(by: 3, latest: (23, 30)))
        - [x] Ask about a late check-in

        """)
        write("Travel/Budget.md", """
        Everything for [[Kyoto trip]], in the currency it gets paid in.

        | Item | Cost | Paid |
        | --- | ---: | --- |
        | Flights | €1,240 | Yes |
        | Ryokan, four nights | ¥88,000 | Yes |
        | Rail pass | ¥50,000 | No |
        | Food and temples | ¥60,000 | No |

        Roughly **€2,450** in total at today's rate.

        The rail pass, from the counter at the station:

        ![](.assets/rail%20pass%20receipt.jpg)

        """)
        write("Personal/Weekend.md", """
        Market on Saturday morning, cooking with Mia in the evening. Sunday stays empty on purpose.

        ## Saturday
        - [ ] Market shopping \(due(1, 9))
            - [ ] Tomatoes and basil
            - [ ] Burrata, from the cheese stall at the back
            - [x] Bags

        Dinner: the mushroom risotto from [[Recipes]].

        """)
        write("Personal/Questions for Dr. Weber.md", """
        Check-up at 9:30 at the practice on Lindenstraße. Bring the insurance card and the list of what I take.

        - [ ] Is the knee pain from running, or something else?
        - [ ] Do I still need vitamin D over the winter?
        - [ ] Referral for physiotherapy
        - [x] Blood test results by email

        Last time: blood pressure 125/80, all fine.

        """)
        write("Personal/Cooking/Recipes.md", """
        ## Mushroom risotto
        1. Sweat a shallot in butter
        2. Toast the rice, then a glass of white wine
        3. Ladle in stock, stir, repeat for 18 minutes
        4. Fold in the mushrooms and *lots* of parmesan

        ```text
        Serves 2 · 320 g rice · 1 l stock
        ```

        """)
        write("Projects/Notebook roadmap.md", """
        How the pieces fit together, and what ships when.

        ## Architecture
        ```mermaid
        graph LR
          Files --> Markdown --> Editor
          Files --> Index --> Search
        ```

        ## Milestones
        | Milestone | Goal | Status |
        | --- | --- | --- |
        | M0 | Editor and file spikes | Done |
        | M1 | Finder replacement | Doing |
        | M2 | Live preview | Next |

        ```swift
        // The editor keeps the Markdown exactly as it is in the file.
        let document = MarkdownParser.parse(text)
        styler.style(storage, document: document)
        ```

        Offer from the agency: [[Offer.pdf]]

        """)
        write("Projects/Design/Meeting notes.md", "# Kick-off\n\n- Keep it **minimal**\n- Notes are plain files\n- ⌥⌘F finds everything\n")
        write("University/Linear algebra/Week 3.md", """
        ## Eigenvalues
        λ is an eigenvalue of $A$ when there is a vector that $A$ only stretches:

        $$
        A\\mathbf{x} = \\lambda\\mathbf{x}, \\quad \\mathbf{x} \\neq 0
        $$

        Find them by solving $\\det(A - \\lambda I) = 0$.

        > [!important] Exam
        > Sheet 3, tasks 2 and 4 by Thursday.

        """)

        drawTorii(to: root.appendingPathComponent("Travel/.assets/torii.png"))
        drawRoute(to: root.appendingPathComponent("Travel/.assets/Getting to the ryokan drawing.png"))
        drawTorii(to: root.appendingPathComponent("Travel/ryokan.jpg"), jpeg: true)
        drawReceipt(to: root.appendingPathComponent("Travel/.assets/rail pass receipt.jpg"))
        makeScan(at: root.appendingPathComponent("Travel/Ryokan confirmation.pdf"), lines: [
            "RYOKAN HANAYA", "Reservation confirmed", "4 nights, 13 to 17 October, two guests",
            "Room Kiku, garden side", "Check-in from 15:00, dinner at 19:00",
        ])
        makePDF(at: root.appendingPathComponent("Travel/Flight tickets.pdf"), title: "Itinerary receipt", lines: [
            "Booking reference K7Q2LM", "Outbound Mon 12 Oct: FRA 13:40 to KIX 08:45, flight XY 2041",
            "Return Sat 17 Oct: KIX 10:55 to FRA 16:15, flight XY 2042", "Haruka express from Kansai Airport to Kyoto Station",
        ])
        makePDF(at: root.appendingPathComponent("Projects/Offer.pdf"), title: "Offer", lines: [
            "Design and build of the Notebook website", "Three pages, light and dark", "Delivery in four weeks",
        ])
        for item in dates {
            try? fm.setAttributes([.modificationDate: Date(timeIntervalSinceNow: -item.edited * 86_400), .creationDate: Date(timeIntervalSinceNow: -item.made * 86_400)],
                                  ofItemAtPath: root.appendingPathComponent(item.path).path)
        }
        return true
    }

    /// A made-up export of Apple Notes, for trying Import from Apple Notes with and taking its pictures: two Notes
    /// folders exported with File › Export as › Markdown, each saved into From Notes under its name, as the README says
    /// to. As Notes writes them, each note starts with its title, and the pictures and files of all of an export's
    /// notes are in its Attachments folder, the pictures without an extension. In Debug builds,
    /// `-NotebookDemoExport YES` with `-NotebookLibrary` writes it next to the library, `-NotebookDemoExport <path>`
    /// there.
    static func createAppleNotesExport(at root: URL) {
        let fm = FileManager.default
        if fm.fileExists(atPath: root.path) { return }
        let recipes = root.appendingPathComponent("Recipes", isDirectory: true)
        let trips = root.appendingPathComponent("Trips", isDirectory: true)
        try? fm.createDirectory(at: recipes, withIntermediateDirectories: true)
        try? fm.createDirectory(at: trips.appendingPathComponent("Attachments"), withIntermediateDirectories: true)
        func write(_ folder: URL, _ name: String, _ text: String, written: String) {
            let url = folder.appendingPathComponent(name)
            try? Data(text.utf8).write(to: url)
            let date = ISO8601DateFormatter().date(from: written + "T09:30:00Z")
            try? fm.setAttributes([.creationDate: date as Any, .modificationDate: date as Any], ofItemAtPath: url.path)
        }

        write(recipes, "Lemon pasta.md", """
        # Lemon pasta

        Serves two, quick on a weeknight.

        ## Ingredients
        - 200 g spaghetti
        - 1 lemon, zest and juice
        - 40 g butter
        - Parmesan

        ## Steps
        1. Cook the pasta in salted water.
        2. Melt the butter with the zest, add the juice and a ladle of pasta water.
        3. Toss with the pasta and the cheese.

        What to buy is in [Weekly shopping](Weekly%20shopping.md).

        """, written: "2026-02-02")
        write(recipes, "Weekly shopping.md", """
        Weekly shopping

        - [x] Spaghetti
        - [ ] Lemons
        - [ ] Butter
        - [x] Parmesan
        - [ ] Olive oil

        """, written: "2026-02-03")
        write(trips, "Osaka weekend.md", """
        Osaka weekend

        Friday to Sunday in March. The train from Tokyo leaves at 7:40.

        | Day | Plan |
        | --- | --- |
        | Friday | Dotonbori, dinner in Shinsekai |
        | Saturday | Osaka Castle, then the aquarium |
        | Sunday | Day trip to Nara, back by 18:10 |

        ![](Attachments/IMG_2050)

        [Hotel booking.pdf](Attachments/Hotel%20booking.pdf)

        What to take is in [Packing list](Packing%20list.md), the shrines in [Shrines to see](Shrines%20to%20see.md).

        """, written: "2026-03-14")
        write(trips, "Shrines to see.md", """
        Shrines to see

        - Sumiyoshi Taisha, early in the morning
        - Kasuga Taisha in Nara, with its lanterns

        ![](Attachments/IMG_2041)

        """, written: "2026-03-10")
        write(trips, "Packing list.md", """
        Packing list

        - [x] Passport
        - [ ] Charger
        - [ ] Rain jacket
        - [ ] Sunglasses

        """, written: "2026-03-12")
        drawReceipt(to: trips.appendingPathComponent("Attachments/IMG_2050.jpg"))
        drawTorii(to: trips.appendingPathComponent("Attachments/IMG_2041.png"))
        for name in ["IMG_2050.jpg", "IMG_2041.png"] {
            let url = trips.appendingPathComponent("Attachments/\(name)")
            try? fm.moveItem(at: url, to: url.deletingPathExtension())
        }
        makeScan(at: trips.appendingPathComponent("Attachments/Hotel booking.pdf"), lines: [
            "HOTEL NAMBA", "Reservation confirmed", "2 nights, 13 to 15 March, two guests", "Check-in from 15:00",
        ])
    }

    /// When each sample was last edited and was made, in days before now, as a few weeks of use leave them, to sort by
    /// date with: the trip planned weeks ago and changed today, a link saved this morning, last year's flat at the
    /// bottom. Folders last, as writing in them changes their dates.
    static let dates: [(path: String, edited: Double, made: Double)] = [
        ("Travel/Kyoto trip.md", 0.01, 23), ("Travel/Budget.md", 1, 20), ("Travel/Getting to the ryokan.md", 2, 9),
        ("Travel/ryokan.jpg", 6, 6), ("Travel/Ryokan confirmation.pdf", 12, 12), ("Travel/Flight tickets.pdf", 30, 30),
        ("Inbox/Shared link.md", 0.1, 0.1), ("Inbox/Errands.md", 0.15, 5), ("Inbox/Gift ideas.md", 4, 40),
        ("Personal/Weekend.md", 0.2, 2), ("Personal/Questions for Dr. Weber.md", 1, 8), ("Personal/Cooking/Recipes.md", 15, 60),
        ("Projects/Notebook roadmap.md", 0.02, 50), ("Projects/Offer.pdf", 10, 10), ("Projects/Design/Meeting notes.md", 7, 49),
        ("University/Linear algebra/Week 3.md", 3, 10), ("Archive/2025/Old apartment.md", 200, 300),
        ("Travel/Photos", 6, 25), ("Personal/Cooking", 15, 60), ("Projects/Design", 7, 50), ("University/Linear algebra", 3, 40),
        ("Archive/2025", 200, 300), ("Travel", 0.5, 30), ("Inbox", 0.1, 60), ("Personal", 2, 60), ("Projects", 10, 50),
        ("University", 3, 40), ("Archive", 200, 300),
    ]

    private static func drawTorii(to url: URL, jpeg: Bool = false) {
        let width = 1400, height = 620
        guard let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                      space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return }
        func fill(_ hex: UInt32) {
            context.setFillColor(red: CGFloat((hex >> 16) & 0xFF) / 255, green: CGFloat((hex >> 8) & 0xFF) / 255, blue: CGFloat(hex & 0xFF) / 255, alpha: 1)
        }
        fill(0xF3CDB0); context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        fill(0xFBE6CB); context.fillEllipse(in: CGRect(x: 960, y: 400, width: 140, height: 140))
        fill(0xD29C84); context.fillEllipse(in: CGRect(x: -200, y: -380, width: 1200, height: 640))
        fill(0xB97968); context.fillEllipse(in: CGRect(x: 600, y: -420, width: 1100, height: 620))
        fill(0xB5321F)
        context.fill([
            CGRect(x: 260, y: 430, width: 600, height: 34), CGRect(x: 300, y: 370, width: 520, height: 22),
            CGRect(x: 340, y: 0, width: 36, height: 450), CGRect(x: 744, y: 0, width: 36, height: 450),
        ])
        guard let image = context.makeImage(),
              let destination = CGImageDestinationCreateWithURL(url as CFURL, (jpeg ? UTType.jpeg : UTType.png).identifier as CFString, 1, nil) else { return }
        CGImageDestinationAddImage(destination, image, jpeg ? [kCGImageDestinationLossyCompressionQuality: 0.85] as CFDictionary : nil)
        CGImageDestinationFinalize(destination)
    }

    /// A sketch of the way from the station to the ryokan, as strokes a pen would make: a drawing to go on drawing in.
    private static func drawRoute(to picture: URL) {
        var strokes: [PKStroke] = []
        func stroke(_ points: [CGPoint], _ type: PKInk.InkType = .pen, _ color: UInt32 = 0x1C1C1E, width: CGFloat = 3) {
            let path = points.enumerated().map { index, point in
                PKStrokePoint(location: point, timeOffset: Double(index) / 120, size: CGSize(width: width, height: width), opacity: 1, force: 1, azimuth: 0, altitude: .pi / 2)
            }
            strokes.append(PKStroke(ink: PKInk(type, color: NSColor(hex: color)), path: PKStrokePath(controlPoints: path, creationDate: Date())))
        }
        /// Through the points as a hand draws: rounded between them, and a little uneven.
        func hand(_ points: [(CGFloat, CGFloat)], smooth: Bool = true, seed: Double = 0) -> [CGPoint] {
            let p = points.map { CGPoint(x: $0.0, y: $0.1) }
            var result: [CGPoint] = []
            for i in 0..<max(1, p.count - 1) {
                let p0 = p[max(0, i - 1)], p1 = p[i], p2 = p[min(p.count - 1, i + 1)], p3 = p[min(p.count - 1, i + 2)]
                let steps = max(2, Int(hypot(p2.x - p1.x, p2.y - p1.y) / 4))
                for step in 0..<steps {
                    let t = CGFloat(step) / CGFloat(steps)
                    var point: CGPoint
                    if smooth {
                        let t2 = t * t, t3 = t2 * t
                        func value(_ a: CGFloat, _ b: CGFloat, _ c: CGFloat, _ d: CGFloat) -> CGFloat {
                            0.5 * (2 * b + (-a + c) * t + (2 * a - 5 * b + 4 * c - d) * t2 + (-a + 3 * b - 3 * c + d) * t3)
                        }
                        point = CGPoint(x: value(p0.x, p1.x, p2.x, p3.x), y: value(p0.y, p1.y, p2.y, p3.y))
                    } else {
                        point = CGPoint(x: p1.x + (p2.x - p1.x) * t, y: p1.y + (p2.y - p1.y) * t)
                    }
                    let n = Double(result.count)
                    point.x += CGFloat(sin(n * 0.31 + seed) * 0.7)
                    point.y += CGFloat(cos(n * 0.23 + seed * 1.7) * 0.7)
                    result.append(point)
                }
            }
            result.append(p[p.count - 1])
            return result
        }
        // The way, marked in yellow under the dashes.
        let way: [(CGFloat, CGFloat)] = [(158, 56), (236, 64), (292, 86), (346, 131), (400, 182), (466, 222), (516, 250)]
        stroke(hand(way, seed: 1), .marker, 0xF2C230, width: 16)
        // The river, between its banks.
        stroke(hand([(8, 120), (110, 104), (220, 132), (340, 112), (460, 140), (632, 112)], seed: 2), .pen, 0x2F6FDE, width: 3.5)
        stroke(hand([(8, 158), (110, 142), (220, 170), (340, 150), (460, 178), (632, 150)], seed: 3), .pen, 0x2F6FDE, width: 3.5)
        // The station, with its tracks.
        stroke(hand([(40, 30), (150, 28), (152, 74), (42, 76), (41, 32)], smooth: false, seed: 4), width: 3)
        stroke(hand([(22, 86), (176, 84)], smooth: false, seed: 5), width: 2.4)
        stroke(hand([(22, 95), (176, 93)], smooth: false, seed: 6), width: 2.4)
        for x in stride(from: CGFloat(30), to: 172, by: 14) { stroke([CGPoint(x: x, y: 81), CGPoint(x: x - 1, y: 100)], width: 2) }
        // The way itself, dashed.
        let line = hand(way, seed: 7)
        var dash: [CGPoint] = []
        var travelled: CGFloat = 0
        for (a, b) in zip(line, line.dropFirst()) {
            travelled += hypot(b.x - a.x, b.y - a.y)
            if travelled.truncatingRemainder(dividingBy: 18) < 11 { dash.append(b) } else if dash.count > 1 { stroke(dash, width: 2.6); dash = [] } else { dash = [] }
        }
        if dash.count > 1 { stroke(dash, width: 2.6) }
        // The second bridge.
        stroke(hand([(326, 98), (329, 166)], smooth: false, seed: 8), width: 3)
        stroke(hand([(364, 96), (367, 164)], smooth: false, seed: 9), width: 3)
        // The ryokan, ringed in red.
        stroke(hand([(506, 232), (556, 194), (604, 232)], smooth: false, seed: 10), width: 3)
        stroke(hand([(516, 230), (516, 274), (596, 274), (596, 230)], smooth: false, seed: 11), width: 3)
        stroke(hand([(549, 274), (549, 252), (563, 252), (563, 274)], smooth: false, seed: 12), width: 2.4)
        let ring = (0...44).map { index -> (CGFloat, CGFloat) in
            let angle = Double(index) / 40 * 2 * .pi - 2.2
            return (556 + CGFloat(cos(angle)) * 72, 236 + CGFloat(sin(angle)) * 54)
        }
        stroke(hand(ring, seed: 13), .pen, 0xE5483E, width: 3)
        // The ryokan's name, written under the way to it, and the station's: words to find in a drawing.
        write("Hanaya", size: 3.2, at: CGPoint(x: 312, y: 268), seed: 20)
        write("Station", size: 2.4, at: CGPoint(x: 60, y: 22), seed: 30)
        DrawingFile(drawing: PKDrawing(strokes: strokes), size: CGSize(width: 640, height: 300)).write(picture: picture)

        /// A word in print as a hand writes it, a stroke for each line of a letter, `at` the start of its baseline.
        func write(_ word: String, size: CGFloat, at origin: CGPoint, seed: Double) {
            var x = origin.x
            for (number, letter) in word.enumerated() {
                guard let shape = letters[letter] else { continue }
                for (index, line) in shape.strokes.enumerated() {
                    let points = line.map { (x + $0.0 * size, origin.y + ($0.1 - 10) * size) }
                    stroke(hand(points, seed: seed + Double(number * 7 + index)), width: 2.6)
                }
                x += (shape.width + 2) * size
            }
        }
    }

    /// Print letters as single strokes, in a box 10 high from the top of a capital to the baseline, the middle of a
    /// small letter at 4.5 and descenders below 10: (width, strokes).
    private static let letters: [Character: (width: CGFloat, strokes: [[(CGFloat, CGFloat)]])] = [
        "H": (6, [[(0, 0), (0, 10)], [(6, 0), (6, 10)], [(0, 5), (6, 5)]]),
        "S": (5.4, [[(5, 1.2), (3.6, 0), (1.6, 0), (0.3, 1.2), (0.6, 3.2), (2.6, 4.6), (4.6, 6), (5.4, 8), (4.4, 9.6), (2.4, 10), (0.4, 9)]]),
        "a": (5, [[(4.6, 5.6), (3.4, 4.6), (1.8, 4.7), (0.4, 6.2), (0.3, 8.4), (1.4, 9.9), (3, 10), (4.6, 8.6)], [(4.8, 4.6), (4.8, 10)]]),
        "n": (4.6, [[(0, 4.5), (0, 10)], [(0, 6.4), (1.3, 4.8), (2.8, 4.5), (4.2, 5.4), (4.6, 7), (4.6, 10)]]),
        "y": (5, [[(0, 4.5), (2.6, 10)], [(5, 4.5), (2.6, 10), (1.6, 12.6), (0.4, 13.4)]]),
        "t": (4, [[(1.8, 1.4), (1.8, 9), (2.6, 10), (3.8, 9.7)], [(0, 4.7), (3.6, 4.7)]]),
        "i": (1, [[(0.5, 4.6), (0.5, 10)], [(0.5, 2.4), (0.6, 2.9)]]),
        "o": (5, [[(2.5, 4.5), (0.8, 5.3), (0, 7.3), (0.8, 9.3), (2.5, 10), (4.2, 9.3), (5, 7.3), (4.2, 5.3), (2.5, 4.5)]]),
    ]

    /// A photo of a receipt from the station's counter, slightly turned, on a wooden table: text to find in a picture.
    private static func drawReceipt(to url: URL) {
        let width = 1100, height = 760
        guard let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                      space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return }
        context.setFillColor(red: 0.62, green: 0.47, blue: 0.34, alpha: 1)
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        context.translateBy(x: CGFloat(width) / 2, y: CGFloat(height) / 2)
        context.rotate(by: -0.035)
        let paper = CGRect(x: -330, y: -340, width: 660, height: 680)
        context.setShadow(offset: CGSize(width: 0, height: -6), blur: 18, color: CGColor(gray: 0, alpha: 0.35))
        context.setFillColor(red: 0.98, green: 0.97, blue: 0.94, alpha: 1)
        context.fill(paper)
        context.setShadow(offset: .zero, blur: 0, color: nil)
        let lines: [(String, CGFloat, Bool)] = [
            ("JR WEST", 30, true), ("KYOTO STATION", 22, false), ("", 14, false),
            ("JAPAN RAIL PASS", 34, true), ("ORDINARY 7 DAYS  1 ADULT", 22, false), ("VALID 12 OCT - 18 OCT", 22, false),
            ("", 14, false), ("TOTAL      JPY 50,000", 28, true), ("PAID BY CARD", 20, false), ("THANK YOU", 20, false),
        ]
        var y = paper.maxY - 70
        for (text, size, bold) in lines {
            let font = CTFontCreateWithName((bold ? "Menlo-Bold" : "Menlo-Regular") as CFString, size, nil)
            let line = CTLineCreateWithAttributedString(NSAttributedString(string: text, attributes: [
                .init(kCTFontAttributeName as String): font,
                .init(kCTForegroundColorAttributeName as String): CGColor(gray: 0.12, alpha: 1),
            ]))
            let lineWidth = CTLineGetTypographicBounds(line, nil, nil, nil)
            context.textPosition = CGPoint(x: -lineWidth / 2, y: y)
            CTLineDraw(line, context)
            y -= size * 1.75
        }
        guard let image = context.makeImage(),
              let destination = CGImageDestinationCreateWithURL(url as CFURL, UTType.jpeg.identifier as CFString, 1, nil) else { return }
        CGImageDestinationAddImage(destination, image, [kCGImageDestinationLossyCompressionQuality: 0.85] as CFDictionary)
        CGImageDestinationFinalize(destination)
    }

    /// A scanned page: a picture of the text with no text of its own, as a scanner or the camera makes it.
    private static func makeScan(at url: URL, lines: [String]) {
        let width = 1240, height = 1754
        guard let page = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                   space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else { return }
        page.setFillColor(red: 0.97, green: 0.97, blue: 0.95, alpha: 1)
        page.fill(CGRect(x: 0, y: 0, width: width, height: height))
        for (index, text) in lines.enumerated() {
            let font = CTFontCreateWithName((index == 0 ? "Georgia-Bold" : "Georgia") as CFString, index == 0 ? 54 : 32, nil)
            let line = CTLineCreateWithAttributedString(NSAttributedString(string: text, attributes: [
                .init(kCTFontAttributeName as String): font,
                .init(kCTForegroundColorAttributeName as String): CGColor(gray: 0.15, alpha: 1),
            ]))
            page.textPosition = CGPoint(x: 120, y: CGFloat(height - 220) - CGFloat(index) * 70 - (index > 0 ? 40 : 0))
            CTLineDraw(line, page)
        }
        guard let image = page.makeImage() else { return }
        var box = CGRect(x: 0, y: 0, width: 595, height: 842)
        guard let context = CGContext(url as CFURL, mediaBox: &box, nil) else { return }
        context.beginPDFPage(nil)
        context.draw(image, in: box)
        context.endPDFPage()
        context.closePDF()
    }

    private static func makePDF(at url: URL, title: String, lines: [String]) {
        var box = CGRect(x: 0, y: 0, width: 595, height: 842)
        guard let context = CGContext(url as CFURL, mediaBox: &box, nil) else { return }
        context.beginPDFPage(nil)
        func draw(_ text: String, size: CGFloat, weight: CTFontUIFontType, at point: CGPoint) {
            let font = CTFontCreateUIFontForLanguage(weight, size, nil)!
            let line = CTLineCreateWithAttributedString(NSAttributedString(string: text, attributes: [.init(kCTFontAttributeName as String): font]))
            context.textPosition = point
            CTLineDraw(line, context)
        }
        draw(title, size: 26, weight: .emphasizedSystem, at: CGPoint(x: 56, y: 766))
        for (index, line) in lines.enumerated() {
            draw(line, size: 13, weight: .system, at: CGPoint(x: 56, y: 713 - CGFloat(index) * 26))
        }
        context.endPDFPage()
        context.closePDF()
    }
}

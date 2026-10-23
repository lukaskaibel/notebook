import Foundation

/// What Customize Folder offers: symbols and emoji in groups, as the emoji picker and Reminders' list icons have them,
/// a few suggested for the folder's name, and search by name and by what they are for.
enum FolderIconCatalog {
    struct Group: Identifiable {
        let title: String
        let items: [String]
        var id: String { title }
    }

    // MARK: - Symbols

    static let symbolGroups: [Group] = [
        Group(title: "Objects", items: [
            "folder", "tray", "tray.full", "tray.2", "archivebox", "doc.text", "doc.richtext", "note.text", "list.bullet.clipboard",
            "checklist", "book", "book.closed", "books.vertical", "text.book.closed", "character.book.closed", "bookmark", "newspaper",
            "magazine", "paperclip", "pencil", "square.and.pencil", "pencil.and.ruler", "pencil.and.scribble", "highlighter", "scissors",
            "paintbrush", "paintbrush.pointed", "paintpalette", "eyedropper", "ruler", "hammer", "wrench.and.screwdriver", "screwdriver",
            "gearshape", "gearshape.2", "key", "lock", "briefcase", "case", "bag", "cart", "basket", "creditcard", "giftcard", "gift",
            "shippingbox", "lightbulb", "lamp.desk", "lamp.floor", "tag", "pin", "mappin", "flag", "bell", "megaphone", "envelope",
            "paperplane", "phone", "bubble.left.and.bubble.right", "quote.bubble", "camera", "photo", "film", "video", "tv",
            "desktopcomputer", "laptopcomputer", "iphone", "ipad", "applewatch", "headphones", "airpods", "gamecontroller", "printer",
            "keyboard", "computermouse", "externaldrive", "server.rack", "cpu", "memorychip", "battery.100", "powerplug", "umbrella",
            "eyeglasses", "sunglasses", "crown", "graduationcap", "studentdesk", "backpack", "puzzlepiece", "dice", "theatermasks",
            "ticket", "trophy", "medal", "balloon", "party.popper",
        ]),
        Group(title: "Music", items: [
            "music.note", "music.note.list", "music.mic", "mic", "guitars", "pianokeys", "metronome", "tuningfork", "speaker.wave.2",
            "hifispeaker", "radio", "waveform",
        ]),
        Group(title: "People", items: [
            "person", "person.2", "person.3", "person.crop.circle", "figure.walk", "figure.run", "figure.stand",
            "figure.and.child.holdinghands", "figure.2.and.child.holdinghands", "figure.2", "brain.head.profile", "brain",
            "hand.raised", "hand.thumbsup", "hand.wave", "hands.clap", "heart", "face.smiling", "eye", "ear", "mouth", "nose",
        ]),
        Group(title: "Health", items: [
            "heart.text.square", "waveform.path.ecg", "cross.case", "stethoscope", "pills", "syringe", "bandage", "lungs", "allergens",
            "staroflife", "bed.double",
        ]),
        Group(title: "Home", items: [
            "house", "building.2", "building", "building.columns", "storefront", "sofa", "chair.lounge", "chair", "washer", "dishwasher",
            "refrigerator", "oven", "stove", "microwave", "cooktop", "fan", "sink", "shower", "bathtub", "toilet", "door.left.hand.open",
            "spigot", "lightbulb.2", "key.horizontal",
        ]),
        Group(title: "Food", items: [
            "fork.knife", "cup.and.saucer", "mug", "wineglass", "waterbottle", "birthday.cake", "carrot", "fish",
            "takeoutbag.and.cup.and.straw", "frying.pan", "popcorn",
        ]),
        Group(title: "Nature", items: [
            "leaf", "tree", "camera.macro", "laurel.leading", "sun.max", "sun.horizon", "moon", "moon.stars", "cloud", "cloud.sun",
            "cloud.rain", "snowflake", "flame", "drop", "bolt", "wind", "tornado", "mountain.2", "globe.europe.africa",
            "globe.americas", "globe.asia.australia", "pawprint", "dog", "cat", "bird", "tortoise", "hare", "ant", "ladybug", "lizard",
            "teddybear",
        ]),
        Group(title: "Travel", items: [
            "airplane", "car", "car.side", "bus", "tram", "train.side.front.car", "bicycle", "scooter", "motorcycle", "sailboat",
            "ferry", "fuelpump", "ev.charger", "parkingsign", "map", "globe", "suitcase", "suitcase.rolling", "beach.umbrella", "tent",
            "signpost.right", "signpost.right.and.left", "binoculars", "location", "mappin.and.ellipse",
        ]),
        Group(title: "Sport", items: [
            "dumbbell", "figure.strengthtraining.traditional", "figure.yoga", "figure.hiking", "figure.outdoor.cycle",
            "figure.pool.swim", "figure.skiing.downhill", "figure.soccer", "figure.tennis", "figure.climbing", "sportscourt",
            "soccerball", "basketball", "tennisball", "tennis.racket", "football", "baseball", "volleyball", "skateboard",
            "flag.checkered",
        ]),
        Group(title: "Work and Study", items: [
            "calendar", "clock", "alarm", "timer", "hourglass", "stopwatch", "chart.bar", "chart.pie", "chart.line.uptrend.xyaxis",
            "dollarsign.circle", "eurosign.circle", "sterlingsign.circle", "yensign.circle", "bitcoinsign.circle", "banknote",
            "signature", "doc.text.magnifyingglass", "function", "sum", "percent", "atom", "flask", "testtube.2", "terminal",
            "chevron.left.forwardslash.chevron.right", "curlybraces", "apple.terminal", "network", "icloud", "magnifyingglass",
            "scope", "target", "globe.desk",
        ]),
        Group(title: "Shapes", items: [
            "star", "sparkles", "sparkle", "circle", "square", "triangle", "diamond", "hexagon", "seal", "shield", "checkmark.seal",
            "checkmark.circle", "exclamationmark.triangle", "questionmark.circle", "info.circle", "plus.circle", "number", "at",
            "link", "infinity", "asterisk", "lasso", "scribble", "peacesign", "command", "option", "recordingtape",
        ]),
    ]

    // MARK: - Emoji

    static let emojiGroups: [Group] = [
        Group(title: "Smileys and People", items: emoji("""
            😀 😃 😄 😁 😆 😅 😂 🙂 😉 😊 😇 🥰 😍 🤩 😘 😋 😎 🤓 🧐 🤔 🤗 🤭 😴 🥳 😌 😬 🙃 😜 🤪 😷 🤯 🥶 🥵 😱 😭 😤 😡 🤠 🥸 👻
            💀 👽 🤖 💩 🎃 😺 👋 ✋ 👌 ✌️ 🤞 👍 👎 👏 🙌 🤝 🙏 💪 🧠 👀 👶 🧒 👧 👦 🧑 👩 👨 🧓 👵 👴 👩‍💻 🧑‍💻 🧑‍🎓 🧑‍🍳 🧑‍🔬 🧑‍🎨
            🧑‍⚕️ 🧑‍🚀 🧑‍🌾 🧑‍🏫 🧙 🧚 🦸 👪 💑 👫
            """)),
        Group(title: "Animals and Nature", items: emoji("""
            🐶 🐱 🐭 🐹 🐰 🦊 🐻 🐼 🐨 🐯 🦁 🐮 🐷 🐸 🐵 🐔 🐧 🐦 🦆 🦉 🦄 🐝 🦋 🐌 🐞 🐢 🐍 🐙 🐬 🐳 🐟 🦀 🐘 🦒 🐎 🐑 🐾 🌵 🌲
            🌳 🌴 🌱 🌿 🍀 🍁 🍂 🌷 🌹 🌻 🌼 🌸 💐 🍄 🌍 🌙 ⭐️ ☀️ 🌈 ☁️ ⛈️ ❄️ 🔥 💧 🌊
            """)),
        Group(title: "Food and Drink", items: emoji("""
            🍏 🍎 🍐 🍊 🍋 🍌 🍉 🍇 🍓 🫐 🍒 🍑 🥭 🍍 🥥 🥝 🍅 🥑 🥦 🥕 🌽 🌶️ 🥔 🥐 🥖 🥨 🧀 🥚 🍳 🥞 🥓 🍔 🍟 🍕 🌮 🌯 🥗 🍝 🍜
            🍣 🍱 🍛 🍤 🍙 🍦 🍩 🍪 🎂 🍰 🧁 🍫 🍿 ☕️ 🍵 🧃 🥤 🍺 🍷 🍸 🍹 🍾
            """)),
        Group(title: "Activity", items: emoji("""
            ⚽️ 🏀 🏈 ⚾️ 🎾 🏐 🏉 🎱 🏓 🏸 🥊 ⛳️ ⛸️ 🎿 🏂 🏋️ 🧘 🏄 🏊 🚴 🧗 🏆 🥇 🏅 🎖️ 🎟️ 🎭 🎨 🎬 🎤 🎧 🎼 🎹 🥁 🎷 🎺 🎸 🎻 🎲
            ♟️ 🎯 🎳 🎮 🧩 🪁 🎣
            """)),
        Group(title: "Travel and Places", items: emoji("""
            🚗 🚕 🚙 🚌 🏎️ 🚓 🚑 🚒 🚚 🚜 🛵 🏍️ 🚲 🛴 🚂 🚆 🚇 🚊 ✈️ 🛫 🚀 🛸 🚁 ⛵️ 🚤 🛳️ ⚓️ 🗺️ 🧭 🏔️ ⛰️ 🌋 🏕️ 🏖️ 🏝️ 🏜️ 🏠
            🏡 🏢 🏥 🏦 🏨 🏫 🏛️ ⛪️ 🕌 🗼 🗽 🏰 🎡 🎢 🌆 🌃 🌉 🗻
            """)),
        Group(title: "Objects", items: emoji("""
            ⌚️ 📱 💻 ⌨️ 🖥️ 🖨️ 🖱️ 💾 💿 📷 🎥 📺 📻 🎙️ ⏰ ⌛️ 💡 🔦 🕯️ 💸 💵 💶 💳 💎 ⚖️ 🔧 🔨 🛠️ ⚙️ 🧲 🔬 🔭 🧪 💊 🩺 🩹 🧹 🧺
            🧼 🛒 🎁 🎈 🎉 🎊 ✉️ 📦 📫 📝 📄 📑 📊 📈 📅 🗂️ 📁 📂 🗃️ 🗄️ 📋 📌 📍 📎 📏 📐 ✂️ 🖊️ ✏️ 🖌️ 🖍️ 🔍 🔒 🔑 🗝️ 📚 📖
            📓 📔 📒 📕 📗 📘 📙 🔖 🏷️
            """)),
        Group(title: "Symbols", items: emoji("""
            ❤️ 🧡 💛 💚 💙 💜 🖤 🤍 🤎 💔 💕 💯 ✅ ☑️ ✔️ ❌ ➕ ❓ ❗️ ⚠️ 🚫 ⛔️ ♻️ ⚜️ ✳️ ✴️ 💠 🔆 ⚡️ 💤 💬 💭 🔔 🎵 🎶 🔁 ▶️
            🔴 🟠 🟡 🟢 🔵 🟣 ⚫️ ⚪️ 🟤 🟥 🟧 🟨 🟩 🟦 🟪 ⬛️ ⬜️ 🔶 🔷 ♠️ ♣️ ♥️ ♦️ ☮️ ☯️ ♾️ ⚛️ 🆕 🆒 🆗 🆘
            """)),
        Group(title: "Flags", items: emoji("""
            🏁 🚩 🏳️ 🏴 🏳️‍🌈 🇪🇺 🇩🇪 🇦🇹 🇨🇭 🇬🇧 🇺🇸 🇫🇷 🇮🇹 🇪🇸 🇵🇹 🇳🇱 🇧🇪 🇩🇰 🇸🇪 🇳🇴 🇫🇮 🇵🇱 🇨🇿 🇬🇷 🇮🇪 🇨🇦 🇲🇽 🇧🇷 🇦🇷 🇯🇵
            🇰🇷 🇨🇳 🇮🇳 🇹🇭 🇻🇳 🇦🇺 🇳🇿 🇿🇦 🇪🇬 🇹🇷 🇺🇦
            """)),
    ]

    private static func emoji(_ list: String) -> [String] {
        list.split(whereSeparator: \.isWhitespace).map(String.init)
    }

    // MARK: - What they are for

    /// Words a folder's name or a search can have, with the symbols and emoji that go with them. Some in German too,
    /// where folder names often are.
    private static let topics: [(words: [String], symbols: [String], emoji: [String])] = [
        (["recipe", "cooking", "cook", "food", "kitchen", "meal", "baking", "rezept", "kochen", "essen", "küche", "backen"],
         ["fork.knife", "frying.pan", "birthday.cake", "carrot", "cup.and.saucer", "cooktop"], ["🍳", "🍝", "🥗", "🎂", "🍕"]),
        (["travel", "trip", "vacation", "holiday", "journey", "reise", "urlaub", "ferien"],
         ["airplane", "suitcase.rolling", "map", "beach.umbrella", "globe.europe.africa", "tent"], ["✈️", "🧳", "🗺️", "🏖️", "🌍"]),
        (["photo", "picture", "image", "photography", "foto", "bild", "bilder"], ["photo", "camera", "camera.macro"], ["📷", "🖼️"]),
        (["work", "job", "office", "business", "client", "customer", "career", "arbeit", "büro", "beruf", "kunde"],
         ["briefcase", "building.2", "calendar", "chart.bar", "person.2"], ["💼", "🏢", "📊"]),
        (["project", "projekt"], ["hammer", "wrench.and.screwdriver", "puzzlepiece", "lightbulb", "target"], ["🛠️", "🧩", "🎯"]),
        (["school", "university", "uni", "study", "studies", "class", "lecture", "course", "homework", "exam", "schule", "studium",
          "vorlesung", "kurs", "prüfung", "hausaufgaben"],
         ["graduationcap", "book", "studentdesk", "pencil.and.ruler", "backpack"], ["🎓", "📚", "✏️", "🏫"]),
        (["math", "maths", "mathematics", "algebra", "calculus", "statistics", "mathe", "mathematik", "analysis"],
         ["function", "sum", "percent", "chart.line.uptrend.xyaxis"], ["📐", "➗", "📈"]),
        (["science", "physics", "chemistry", "biology", "research", "lab", "physik", "chemie", "biologie", "forschung"],
         ["atom", "flask", "testtube.2", "doc.text.magnifyingglass"], ["🔬", "🧪", "⚛️"]),
        (["home", "house", "apartment", "flat", "household", "zuhause", "haus", "wohnung", "haushalt"],
         ["house", "sofa", "key", "lightbulb.2", "washer"], ["🏠", "🛋️", "🔑"]),
        (["money", "finance", "budget", "tax", "bank", "bill", "invoice", "expense", "insurance", "geld", "finanzen", "steuer",
          "rechnung", "versicherung"],
         ["dollarsign.circle", "eurosign.circle", "banknote", "creditcard", "chart.pie"], ["💶", "💳", "🏦"]),
        (["health", "medical", "doctor", "therapy", "gesundheit", "arzt", "medizin"],
         ["heart.text.square", "cross.case", "stethoscope", "pills"], ["🩺", "💊", "❤️"]),
        (["fitness", "gym", "sport", "workout", "training", "running", "run", "yoga", "laufen"],
         ["dumbbell", "figure.run", "figure.yoga", "sportscourt", "soccerball"], ["🏋️", "🏃", "⚽️", "🧘"]),
        (["music", "song", "band", "guitar", "piano", "lyrics", "musik", "lied", "lieder"],
         ["music.note", "guitars", "pianokeys", "headphones", "music.mic"], ["🎵", "🎸", "🎹", "🎧"]),
        (["movie", "film", "video", "series", "cinema", "kino", "serie"], ["film", "tv", "popcorn", "video"], ["🎬", "🍿", "📺"]),
        (["book", "reading", "library", "literature", "buch", "bücher", "lesen"], ["book", "books.vertical", "book.closed", "bookmark"],
         ["📚", "📖", "🔖"]),
        (["journal", "diary", "tagebuch", "log"], ["book.closed", "pencil", "calendar"], ["📔", "✍️"]),
        (["idea", "brainstorm", "inspiration", "idee"], ["lightbulb", "sparkles", "brain.head.profile"], ["💡", "✨", "🧠"]),
        (["archive", "old", "archiv"], ["archivebox", "tray.full", "clock"], ["🗄️", "📦"]),
        (["inbox", "eingang"], ["tray", "tray.and.arrow.down"], ["📥"]),
        (["personal", "private", "me", "persönlich", "privat"], ["person", "person.crop.circle", "heart"], ["🙂", "❤️"]),
        (["family", "kids", "children", "familie", "kinder"], ["figure.2.and.child.holdinghands", "house", "heart"], ["👪", "🏡"]),
        (["friend", "people", "contact", "freunde", "leute"], ["person.2", "person.3", "hands.clap"], ["👫", "🤝"]),
        (["meeting", "call", "besprechung", "termin"], ["person.3", "bubble.left.and.bubble.right", "calendar", "phone"], ["🗓️", "💬"]),
        (["code", "coding", "programming", "dev", "development", "software", "app", "programmieren", "entwicklung"],
         ["chevron.left.forwardslash.chevron.right", "terminal", "curlybraces", "hammer", "cpu"], ["💻", "⌨️", "🤖"]),
        (["design", "art", "drawing", "sketch", "illustration", "kunst", "zeichnung", "skizze"],
         ["paintbrush", "paintpalette", "pencil.and.scribble", "eyedropper"], ["🎨", "🖌️", "✏️"]),
        (["writing", "draft", "blog", "essay", "story", "text", "schreiben", "entwurf"], ["pencil", "square.and.pencil", "doc.text", "note.text"],
         ["✍️", "📝"]),
        (["garden", "plant", "nature", "garten", "pflanze", "natur"], ["leaf", "tree", "camera.macro", "sun.max"], ["🌱", "🌻", "🌳"]),
        (["pet", "dog", "cat", "animal", "haustier", "hund", "katze", "tier"], ["pawprint", "dog", "cat", "bird"], ["🐶", "🐱", "🐾"]),
        (["car", "vehicle", "auto"], ["car", "car.side", "fuelpump", "ev.charger"], ["🚗"]),
        (["game", "gaming", "play", "spiel", "spiele"], ["gamecontroller", "puzzlepiece", "dice"], ["🎮", "🎲", "🧩"]),
        (["shopping", "grocery", "groceries", "einkaufen", "einkauf"], ["cart", "bag", "basket"], ["🛒", "🛍️"]),
        (["gift", "present", "birthday", "geschenk", "geburtstag"], ["gift", "birthday.cake", "party.popper"], ["🎁", "🎂", "🎉"]),
        (["event", "party", "wedding", "fest", "feier", "hochzeit"], ["party.popper", "balloon", "calendar"], ["🎉", "🥂", "💍"]),
        (["calendar", "plan", "planning", "schedule", "kalender", "planung"], ["calendar", "clock", "checklist"], ["📅", "🗓️"]),
        (["todo", "task", "aufgabe"], ["checklist", "checkmark.circle", "list.bullet.clipboard"], ["✅", "📋"]),
        (["language", "vocabulary", "german", "english", "french", "spanish", "sprache", "vokabeln", "deutsch", "englisch",
          "französisch", "spanisch"],
         ["character.book.closed", "globe", "bubble.left.and.bubble.right"], ["🗣️", "🌐"]),
        (["weather", "wetter"], ["cloud.sun", "sun.max", "cloud.rain", "snowflake"], ["☀️", "🌦️"]),
        (["document", "paper", "form", "contract", "dokument", "unterlagen", "vertrag", "formular"],
         ["doc.text", "doc.richtext", "signature", "paperclip"], ["📄", "📎", "🗂️"]),
        (["settings", "config", "admin", "einstellungen"], ["gearshape", "gearshape.2", "wrench.and.screwdriver"], ["⚙️"]),
        (["security", "password", "secret", "sicherheit", "passwort", "geheim"], ["lock", "key", "shield"], ["🔒", "🔑"]),
        (["mail", "letter", "post", "brief"], ["envelope", "paperplane"], ["✉️", "📫"]),
        (["news", "nachrichten", "zeitung"], ["newspaper", "megaphone"], ["📰"]),
        (["podcast", "radio", "audio"], ["mic", "waveform", "radio", "headphones"], ["🎙️", "🎧"]),
        (["star", "favorite", "favourite", "important", "wichtig", "favorit"], ["star", "sparkles", "flag", "exclamationmark.triangle"],
         ["⭐️", "❗️"]),
    ]

    /// Every symbol Customize Folder can show, for tests to see that this system has them all.
    static var everySymbol: [String] { unique(symbolGroups.flatMap(\.items) + topics.flatMap(\.symbols)) }

    /// Symbols for a folder's name: those that go with its words ("Recipes", "Uni Lectures"), best first.
    static func suggestedSymbols(for name: String) -> [String] {
        unique(matchingTopics(for: words(in: name)).flatMap(\.symbols))
    }

    static func suggestedEmoji(for name: String) -> [String] {
        unique(matchingTopics(for: words(in: name)).flatMap(\.emoji))
    }

    /// The topics a word of a name is about: the same word, or one starting like it ("Recipes", "Rezepte"), from four
    /// letters on.
    private static func matchingTopics(for words: [String]) -> [(words: [String], symbols: [String], emoji: [String])] {
        topics.filter { topic in words.contains { word in topic.words.contains { matches(word, $0) } } }
    }

    /// A short word only as it is, or with an "s" ("app" isn't "apple").
    private static func matches(_ word: String, _ topicWord: String) -> Bool {
        if word == topicWord || word == topicWord + "s" { return true }
        guard word.count >= 4, topicWord.count >= 4 else { return false }
        return word.hasPrefix(topicWord) || topicWord.hasPrefix(word)
    }

    private static func words(in text: String) -> [String] {
        text.lowercased().split { !$0.isLetter }.map(String.init)
    }

    private static func unique(_ items: [String]) -> [String] {
        var seen = Set<String>()
        return items.filter { seen.insert($0).inserted }
    }

    // MARK: - Search

    /// The symbols a search finds: by the words of their names ("fork knife", "plane"), by what they are for ("recipe"),
    /// and by their group ("travel"). Every word typed has to match.
    static func symbols(matching query: String) -> [String] {
        found(in: searchableSymbols, query)
    }

    /// The emoji a search finds: by their Unicode names ("pizza", "heart"), by country for flags, by what they are
    /// for, and by their group. Every emoji there is, not only those shown.
    static func emoji(matching query: String) -> [String] {
        found(in: searchableEmoji, query)
    }

    /// A word typed matches a word it starts, or from four letters on one it is in ("plane" in "airplane").
    private static func found(in list: [(item: String, about: [String])], _ query: String) -> [String] {
        let typed = words(in: query)
        guard !typed.isEmpty else { return [] }
        return list.filter { entry in
            typed.allSatisfy { word in entry.about.contains { $0.hasPrefix(word) || word.count >= 4 && $0.contains(word) } }
        }.map(\.item)
    }

    /// Every symbol with the words it is found by, worked out once.
    private static let searchableSymbols: [(item: String, about: [String])] = {
        var about: [String: [String]] = [:]
        for group in symbolGroups {
            for symbol in group.items { about[symbol, default: symbol.split(separator: ".").map(String.init)] += words(in: group.title) }
        }
        for topic in topics {
            for symbol in topic.symbols where about[symbol] != nil { about[symbol]? += topic.words }
        }
        return unique(symbolGroups.flatMap(\.items)).map { ($0, about[$0] ?? []) }
    }()

    /// Every emoji with the words it is found by, worked out once.
    private static let searchableEmoji: [(item: String, about: [String])] = {
        var list: [(String, [String])] = []
        var index: [String: Int] = [:]
        func add(_ emoji: String, group: String?) {
            if let at = index[emoji] {
                if let group { list[at].1 += words(in: group) }
                return
            }
            index[emoji] = list.count
            list.append((emoji, words(in: name(of: emoji)) + (group.map(words) ?? [])))
        }
        for group in emojiGroups {
            for emoji in group.items { add(emoji, group: group.title) }
        }
        for topic in topics {
            for emoji in topic.emoji {
                add(emoji, group: nil)
                list[index[emoji]!].1 += topic.words
            }
        }
        // The rest of Unicode's emoji, which show as emoji by themselves.
        for range in [0x2300...0x27BF, 0x1F300...0x1FAFF] {
            for value in range {
                guard let scalar = Unicode.Scalar(value), scalar.properties.isEmojiPresentation, !(0x1F3FB...0x1F3FF).contains(value) else { continue }
                add(String(scalar), group: nil)
            }
        }
        return list
    }()

    /// An emoji's name: Unicode's ("SLICE OF PIZZA"), or a flag's country.
    static func name(of emoji: String) -> String {
        let scalars = emoji.unicodeScalars
        let indicators = scalars.compactMap { (0x1F1E6...0x1F1FF).contains($0.value) ? Character(Unicode.Scalar($0.value - 0x1F1E6 + 65)!) : nil }
        if indicators.count == 2, scalars.count == 2 {
            let code = String(indicators)
            return [Locale.current.localizedString(forRegionCode: code), Locale(identifier: "en").localizedString(forRegionCode: code), code]
                .compactMap { $0 }.joined(separator: " ") + " flag"
        }
        return scalars.compactMap { scalar -> String? in
            guard scalar.value != 0xFE0F, scalar.value != 0x200D, !(0x1F3FB...0x1F3FF).contains(scalar.value) else { return nil }
            return scalar.properties.name
        }.joined(separator: " ")
    }
}

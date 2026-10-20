import Foundation
import Testing
@testable import NotebookKit

/// The typing rules, written as text with `|` for the caret and `‹…›` for a selection.
@Suite("Typing Markdown")
struct MarkdownEditingTests {
    typealias Editing = MarkdownEditing

    func state(_ marked: String) -> Editing.State {
        var text = ""
        var start: Int?
        var end: Int?
        for character in marked {
            switch character {
            case "|": start = text.utf16.count; end = start
            case "‹": start = text.utf16.count
            case "›": end = text.utf16.count
            default: text.append(character)
            }
        }
        let location = start ?? text.utf16.count
        return Editing.State(text, selection: NSRange(location: location, length: (end ?? location) - location))
    }

    func marked(_ state: Editing.State?) -> String? {
        guard let state else { return nil }
        let text = NSMutableString(string: state.text)
        if state.selection.length == 0 {
            text.insert("|", at: state.selection.location)
        } else {
            text.insert("›", at: NSMaxRange(state.selection))
            text.insert("‹", at: state.selection.location)
        }
        return text as String
    }

    func toggled(_ style: Editing.Style, _ text: String) -> String? {
        marked(Editing.toggle(style, in: state(text)).state)
    }

    // MARK: Styles

    @Test func boldStartsAnEmptyPairToTypeInto() {
        #expect(toggled(.bold, "Hello |") == "Hello **|**")
        #expect(toggled(.bold, "|") == "**|**")
    }

    @Test func boldAgainOnAnEmptyPairTakesItAway() {
        #expect(toggled(.bold, "Hello **|**") == "Hello |")
        #expect(toggled(.italic, "a _|_") == "a |")
    }

    @Test func boldAtTheEndOfBoldTextLeavesIt() {
        #expect(toggled(.bold, "**bold|** text") == "**bold**| text")
        #expect(toggled(.bold, "**_both|_**") == "**_both_**|")
        #expect(toggled(.italic, "**_both|_**") == "**_both_|**")
    }

    @Test func leavingBoldTakesTheSpacesTypedLastAlong() {
        #expect(toggled(.bold, "a **bold |**") == "a **bold** |")
        #expect(marked(Editing.insertNewline(in: state("a **bold |**"))) == "a **bold**\n|")
    }

    @Test func boldJustBehindBoldTextGoesBackIn() {
        #expect(toggled(.bold, "**bold**| text") == "**bold|** text")
    }

    @Test func boldInsideBoldTextTakesItOff() {
        #expect(toggled(.bold, "a **bo|ld** b") == "a bo|ld b")
        #expect(toggled(.bold, "a **|bold** b") == "a |bold b")
        #expect(toggled(.code, "run `sw|ift test`") == "run sw|ift test")
        #expect(toggled(.strikethrough, "~~ol|d~~") == "ol|d")
    }

    @Test func aSecondPressPutsTheBoldBack() {
        let first = Editing.toggle(.bold, in: state("a **two wo|rds** b"))
        #expect(marked(first.state) == "a two wo|rds b")
        let second = Editing.toggle(.bold, in: first.state, restoring: first.unwrapped)
        #expect(marked(second.state) == "a **two wo|rds** b")
    }

    @Test func boldInsideAWordStylesTheWord() {
        #expect(toggled(.bold, "a wo|rd b") == "a **wo|rd** b")
        #expect(toggled(.italic, "a wo|rd b") == "a _wo|rd_ b")
        // Next to a letter italics take *, since _ doesn't work there in Markdown.
        #expect(toggled(.italic, "word|") == "word*|*")
        #expect(toggled(.italic, "a |") == "a _|_")
    }

    @Test func aSelectionIsWrappedAndUnwrapped() {
        #expect(toggled(.bold, "a ‹two words› b") == "a **‹two words›** b")
        #expect(toggled(.bold, "a **‹two words›** b") == "a ‹two words› b")
        #expect(toggled(.bold, "a ‹**two words**› b") == "a ‹two words› b")
        // Spaces stay outside the marks.
        #expect(toggled(.bold, "a‹ word ›b") == "a **‹word›** b")
    }

    @Test func partOfBoldTextLosesItsBold() {
        #expect(toggled(.bold, "**one ‹two› three**") == "**one** ‹two› **three**")
        #expect(toggled(.bold, "**‹one› two**") == "‹one› **two**")
    }

    @Test func aSelectionTakesInBoldItTouches() {
        #expect(toggled(.bold, "‹a **b›** c") == "**‹a b›** c")
    }

    @Test func aSelectionOverLinesStylesEachLineButNotItsMarker() {
        #expect(toggled(.bold, "- ‹one\n- two›") == "- **‹one**\n- **two›**")
        #expect(toggled(.bold, "- **‹one**\n- **two›**") == "- ‹one\n- two›")
    }

    // MARK: Deleting

    func deletedBackward(_ text: String) -> String? {
        marked(Editing.deleteBackward(in: state(text)))
    }

    @Test func deletingBehindBoldTakesAStarFromBothEnds() {
        #expect(deletedBackward("**bold**|") == "*bold*|")
        #expect(deletedBackward("*bold*|") == "bold|")
        #expect(deletedBackward("a **b**| c") == "a *b*| c")
        #expect(deletedBackward("**_ab_**|") == "*_ab_*|")
        #expect(deletedBackward("~~old~~|") == "old|")
        #expect(deletedBackward("==mark==|") == "mark|")
        #expect(deletedBackward("`code`|") == "code|")
        #expect(marked(Editing.deleteForward(in: state("|**bold**"))) == "|*bold*")
        #expect(marked(Editing.deleteForward(in: state("|*bold*"))) == "|bold")
    }

    @Test func deletingAMarkTakesOneOfItsPartnerToo() {
        #expect(deletedBackward("a **|bold** b") == "a *|bold* b")
        #expect(deletedBackward("a *|*bold** b") == "a |*bold* b")
        #expect(deletedBackward("a **bold*|* b") == "a *bold|* b")
        #expect(deletedBackward("_|x_") == "|x")
    }

    @Test func deletingTheLastMarksRemembersTheirText() {
        let deletion = Editing.deleting(state("a *bold*| b"), forward: false)
        #expect(marked(deletion?.state) == "a bold| b")
        #expect(deletion?.unmarked == NSRange(location: 2, length: 4))
        #expect(Editing.deleting(state("**bold**|"), forward: false)?.unmarked == nil, "still italics")
        #expect(Editing.deleting(state("bold|"), forward: false) == nil)
    }

    @Test func deletingAnEmptyPairTakesBothMarks() {
        #expect(deletedBackward("a **|**") == "a |")
    }

    @Test func spansThatMeetAreNotAnEmptyPair() {
        #expect(deletedBackward("**a**|**b**") == "*a*|**b**")
    }

    @Test func deletingIntoAListMarkerTakesTheMarker() {
        #expect(deletedBackward("- |item") == "|item")
        #expect(deletedBackward("  - |item") == "  |item")
        #expect(deletedBackward("1. |item") == "|item")
        #expect(deletedBackward("> |quote") == "|quote")
        #expect(deletedBackward("## |Title") == "|Title")
        // The box first, then the bullet.
        #expect(deletedBackward("- [ ] |todo") == "- |todo")
        #expect(deletedBackward("- [x|] todo") == "- |todo")
        // One # of several is just deleted.
        #expect(deletedBackward("##| Title") == nil)
        #expect(deletedBackward("plain |text") == nil)
    }

    @Test func deletingASelectionWithOneMarkTakesTheOther() {
        #expect(deletedBackward("‹**bo›ld** x") == "|ld x")
        #expect(deletedBackward("a ‹word›") == nil)
        #expect(deletedBackward("‹**bold**› x") == nil)
    }

    @Test func forwardDeleteIsTheMirrorImage() {
        #expect(marked(Editing.deleteForward(in: state("|**bold**"))) == "|*bold*")
        #expect(marked(Editing.deleteForward(in: state("**bold|**"))) == "*bold|*")
        #expect(marked(Editing.deleteForward(in: state("|**b** x"))) == "|*b* x")
        #expect(marked(Editing.deleteForward(in: state("|- item"))) == "|item")
    }

    // MARK: Return

    func newline(_ text: String) -> String? {
        marked(Editing.insertNewline(in: state(text)))
    }

    @Test func returnLeavesBold() {
        #expect(newline("**bold|**") == "**bold**\n|")
        #expect(newline("**_both|_**") == "**_both_**\n|")
        #expect(newline("**|**") == "\n|")
    }

    @Test func returnInTheMiddleOfBoldSplitsIt() {
        #expect(newline("**bo|ld**") == "**bo**\n**|ld**")
        #expect(newline("**one |two**") == "**one** \n**|two**")
        #expect(newline("a **|bold**") == "a \n**|bold**")
    }

    @Test func returnContinuesAList() {
        #expect(newline("- one|") == "- one\n- |")
        #expect(newline("* one|") == "* one\n* |")
        #expect(newline("  - one|") == "  - one\n  - |")
        #expect(newline("9. one|") == "9. one\n10. |")
        #expect(newline("1) one|") == "1) one\n2) |")
        #expect(newline("- [x] done|") == "- [x] done\n- [ ] |")
        #expect(newline("> quoted|") == "> quoted\n> |")
        #expect(newline("- on|e") == "- on\n- |e")
        #expect(newline("- **bold|**") == "- **bold**\n- |")
        #expect(newline("- **bo|ld**") == "- **bo**\n- **|ld**")
    }

    @Test func returnOnAnEmptyItemEndsTheList() {
        #expect(newline("- one\n- |") == "- one\n|")
        #expect(newline("- [ ] |") == "|")
        #expect(newline("- one\n  - |") == "- one\n- |")
        #expect(newline("> |") == "|")
    }

    @Test func returnElsewhereIsAsUsual() {
        #expect(newline("plain|") == nil)
        #expect(newline("|- one") == nil)
        #expect(newline("**bold**|") == nil)
        #expect(newline("```\n- code|\n```") == nil)
    }

    // MARK: Typing

    func typed(_ character: String, _ text: String) -> String? {
        marked(Editing.insert(character, in: state(text)))
    }

    @Test func aDashStartsABullet() {
        #expect(typed("-", "|") == "- |")
        #expect(typed("-", "a\n  |") == "a\n  - |")
        #expect(typed("-", "|text") == "- |text")
        #expect(typed("-", "a |") == nil)
        #expect(typed("-", "```\n|") == nil)
    }

    @Test func threeDashesStillMakeARule() {
        #expect(typed("-", "- |") == "--|")
        #expect(typed("-", "--|") == nil)
    }

    @Test func aSpaceAfterTheMarkersOwnIsLeftOut() {
        #expect(typed(" ", "- |") == "- |")
        #expect(typed(" ", "- [ ] |") == "- [ ] |")
        #expect(typed(" ", "# |") == "# |")
        #expect(typed(" ", "- a|") == nil)
    }

    @Test func bracketsMakeACheckbox() {
        #expect(typed("]", "- [|") == "- [ ] |")
        #expect(typed("]", "- [ |") == "- [ ] |")
        #expect(typed("]", "- [x|") == "- [x] |")
        #expect(typed("]", "  1. [|") == "  1. [ ] |")
        #expect(typed("]", "[|") == nil)
    }

    @Test func aStarAtEitherEndOfItalicsGoesOnTheOtherEndToo() {
        #expect(typed("*", "*bold*|") == "**bold**|")
        #expect(typed("_", "a _bold_| b") == "a __bold__| b")
        #expect(typed("*", "|*bold*") == "*|*bold**")
        #expect(typed("*", "*|bold*") == "**|bold**")
        // Bold stays as it is.
        #expect(typed("*", "**bold**|") == nil)
        #expect(typed("_", "*bold*|") == nil)
    }

    @Test func aStarWhereMarksWereDeletedBringsThemBack() {
        let deleted = Editing.deleting(state("**bold**|"), forward: false)!
        let plain = Editing.deleting(deleted.state, forward: false)!
        #expect(marked(plain.state) == "bold|")
        let italic = Editing.insert("*", in: plain.state, unmarked: plain.unmarked)
        #expect(marked(italic) == "*bold*|")
        #expect(marked(italic.flatMap { Editing.insert("*", in: $0) }) == "**bold**|")
        let front = Editing.deleting(state("|*bold*"), forward: true)!
        #expect(marked(Editing.insert("*", in: front.state, unmarked: front.unmarked)) == "*|bold*")
        // Without the memory, a star is just typed.
        #expect(typed("*", "bold|") == nil)
    }

    @Test func typingAClosingMarkStepsOverIt() {
        #expect(typed("*", "**bold|**") == "**bold*|*")
        #expect(typed("*", "**bold*|*") == "**bold**|")
        #expect(typed("`", "`code|`") == "`code`|")
        #expect(typed("*", "a |") == nil)
    }

    // MARK: Lists

    @Test func listButtonsTurnLinesIntoListsAndBack() {
        #expect(marked(Editing.toggle(.bullet, in: state("item|"))) == "- item|")
        #expect(marked(Editing.toggle(.bullet, in: state("- item|"))) == "item|")
        #expect(marked(Editing.toggle(.checklist, in: state("- item|"))) == "- [ ] item|")
        #expect(marked(Editing.toggle(.checklist, in: state("- [x] item|"))) == "item|")
        #expect(marked(Editing.toggle(.ordered, in: state("‹one\ntwo›"))) == "1. ‹one\n2. two›")
        #expect(marked(Editing.toggle(.checklist, in: state("|"))) == "- [ ] |")
        #expect(marked(Editing.toggle(.bullet, in: state("  indented|"))) == "  - indented|")
    }

    @Test func checkboxesTick() {
        #expect(marked(Editing.toggleCheckbox(in: state("- [ ] to|do"))) == "- [x] to|do")
        #expect(marked(Editing.toggleCheckbox(in: state("- [x] to|do"))) == "- [ ] to|do")
        #expect(Editing.toggleCheckbox(in: state("- to|do")) == nil)
    }

    @Test func itemsGoInUnderTheItemAboveAndOut() {
        #expect(marked(Editing.indent(in: state("- one\n- two|"))) == "- one\n  - two|")
        #expect(marked(Editing.indent(in: state("1. one\n2. two|"))) == "1. one\n   2. two|")
        #expect(marked(Editing.outdent(in: state("- one\n  - two|"))) == "- one\n- two|")
        #expect(Editing.outdent(in: state("- one|")) == nil)
        #expect(Editing.indent(in: state("plain|")) == nil)
    }

    // MARK: Context

    @Test func theContextNamesTheStylesAndTheLine() {
        let context = Editing.context(in: state("- [ ] **bo|ld** and _x_"))
        #expect(context.styles == [.bold])
        #expect(context.isChecklist)
        #expect(context.isList)
        #expect(Editing.context(in: state("**_a|_**")).styles == [.bold, .italic])
        #expect(Editing.context(in: state("**|**")).styles == [.bold])
        #expect(Editing.context(in: state("**a**|")).styles.isEmpty)
        #expect(Editing.context(in: state("see [the docs](https://example.com/do|cs)")).link == URL(string: "https://example.com/docs"))
        #expect(Editing.context(in: state("- a\n  - nested|")).canOutdent)
        #expect(Editing.context(in: state("- a\n- b|")).canIndent)
        #expect(!Editing.context(in: state("- a|")).canIndent)
        #expect(!Editing.context(in: state("- a\n  - b|")).canIndent)
    }

    // MARK: Applying

    @Test func theDifferenceIsTheSmallestReplacement() {
        let change = Editing.difference(from: "a **bold** b", to: "a bold b")
        #expect(change.range == NSRange(location: 2, length: 8))
        #expect(change.replacement == "bold")
        let emoji = Editing.difference(from: "a🎉b", to: "a🎊b")
        #expect(emoji.range == NSRange(location: 1, length: 2))
    }

    // MARK: Notebook's own Markdown

    @Test func highlightsTurnOnAndOffLikeTheOtherStyles() {
        #expect(toggled(.highlight, "a wo|rd b") == "a ==wo|rd== b")
        #expect(toggled(.highlight, "==marked|==") == "==marked==|")
        #expect(toggled(.highlight, "==ma|rked==") == "ma|rked")
        #expect(deletedBackward("==ab==|") == "ab|")
        #expect(newline("==mark|==") == "==mark==\n|")
        #expect(typed("=", "==mark|==") == "==mark=|=")
        #expect(Editing.context(in: state("==ma|rk==")).styles == [.highlight])
    }

    @Test func nothingIsMarkdownInATildeFence() {
        #expect(typed("-", "~~~\n|") == nil)
        #expect(newline("~~~\n**a|**\n~~~") == nil)
    }

    @Test func returnCarriesANestedQuoteOnWhole() {
        #expect(newline("> > deep|") == "> > deep\n> > |")
        #expect(newline("> > |") == "|")
    }

    @Test func boldAndItalicsInsideEachOtherAreBothFound() {
        let text = "**_both_** and _**both**_ and a*b*c" as NSString
        let spans = MarkdownSyntax.spans(in: text, NSRange(location: 0, length: text.length))
        #expect(spans.filter { $0.style == .italic }.count == 3)
        #expect(spans.filter { $0.style == .bold }.count == 2)
    }
}

import AppKit
import SwiftUI

// AskUserQuestions — fluid-demo/components/ui/ask-user-questions.tsx.
// A question card: semibold title, option rows with numbered shortcut
// chips, merged bg-active blocks over contiguous selections, a morphing
// keyboard-focus ring, an optional free-text "Other" row (or a whole
// freeText question), and a footer with ← Back / Skip → / Continue ⌘↵.
//
// Keyboard contract (verbatim):
//   1-9 pick an option (digit n-1 → row n; the Other row takes the digit
//   after the last option), ↑/↓ cycle rows, ← Back, → Skip, ⌘↵ Continue,
//   Space/Enter on a focused row selects. Single-select advances on click;
//   multi-select and freeText wait for the submit button.

// MARK: - Models

struct FluidAskOption: Identifiable, Equatable {
    var id: String
    var title: String
    var description: String? = nil
    init(id: String? = nil, title: String, description: String? = nil) {
        self.id = id ?? title
        self.title = title
        self.description = description
    }
}

struct FluidAskQuestion: Identifiable, Equatable {
    var id: String
    var title: String
    var options: [FluidAskOption] = []
    var multiSelect = false
    var allowOther = false
    var otherPlaceholder: String? = nil
    var skippable = true
    var nextLabel: String? = nil
    var stacked = false
    var chipPosition: FluidAskChipPosition = .right
    /// A single growing text field as the whole answer (no option rows).
    var freeText = false
    var freeTextPlaceholder: String? = nil
    var freeTextMultiline = true
    /// Return an error string to block submission; nil allows it.
    var freeTextValidate: ((String) -> String?)? = nil

    var _id: String { id }
    var identifiedId: String { id }

    init(id: String? = nil, title: String, options: [FluidAskOption] = [],
         multiSelect: Bool = false, allowOther: Bool = false,
         otherPlaceholder: String? = nil, skippable: Bool = true,
         nextLabel: String? = nil, stacked: Bool = false,
         chipPosition: FluidAskChipPosition = .right,
         freeText: Bool = false, freeTextPlaceholder: String? = nil,
         freeTextMultiline: Bool = true,
         freeTextValidate: ((String) -> String?)? = nil) {
        self.id = id ?? title
        self.title = title
        self.options = options
        self.multiSelect = multiSelect
        self.allowOther = allowOther
        self.otherPlaceholder = otherPlaceholder
        self.skippable = skippable
        self.nextLabel = nextLabel
        self.stacked = stacked
        self.chipPosition = chipPosition
        self.freeText = freeText
        self.freeTextPlaceholder = freeTextPlaceholder
        self.freeTextMultiline = freeTextMultiline
        self.freeTextValidate = freeTextValidate
    }

    static func == (a: FluidAskQuestion, b: FluidAskQuestion) -> Bool { a.id == b.id }
}

enum FluidAskChipPosition { case left, right }

struct FluidAskAnswer: Equatable {
    var selectedIds: Set<String> = []
    var otherText: String? = nil
    var skipped = false
}

// MARK: - Card

struct FluidAskUserQuestions: View {
    var questions: [FluidAskQuestion]
    var size: FluidSize = .default
    var skipLabel = "Skip"
    /// Embedded presentation: the question rows sit in a composer's
    /// attachment slot and the composer editor IS the Other/freeText field.
    var embedded = false
    var index: Binding<Int>? = nil
    var answers: Binding<[String: FluidAskAnswer]>? = nil
    var onSkip: (String, Int) -> Void = { _, _ in }
    var onComplete: ([String: FluidAskAnswer]) -> Void = { _ in }

    @State private var fallbackIndex = 0
    @State private var fallbackAnswers: [String: FluidAskAnswer] = [:]
    @State private var hover = FluidHover(axis: .y)
    @State private var freeTextError: String? = nil
    @State private var otherMultiline = false
    // Plain state, not @FocusState — same trap as FluidInputMessage: an
    // unbound FocusState resets to false and updateNSView drops focus.
    @State private var fieldFocused = false
    /// Logical focus — the source scopes shortcuts to whichever card holds
    /// DOM focus. AppKit pointer clicks don't move first responder (and
    /// single-select navigation rebuilds the row tree), so the card arms on
    /// pointer interaction and the key probe below plays root keydown.
    @State private var armed = false
    /// Set once the last question completes — gates ⌘↵ so a late press
    /// doesn't re-fire `onComplete` (the card holds its final question).
    @State private var completed = false
    @FocusState private var cardFocused: Bool
    @FocusState private var focusedRow: Int?

    init(questions: [FluidAskQuestion], size: FluidSize = .default,
         skipLabel: String = "Skip",
         index: Binding<Int>? = nil,
         answers: Binding<[String: FluidAskAnswer]>? = nil,
         onSkip: @escaping (String, Int) -> Void = { _, _ in },
         onComplete: @escaping ([String: FluidAskAnswer]) -> Void = { _ in }) {
        self.questions = questions; self.size = size
        self.skipLabel = skipLabel
        self.index = index; self.answers = answers
        self.onSkip = onSkip; self.onComplete = onComplete
    }

    // Convenience for the embedded presentation.
    init(questions: [FluidAskQuestion], size: FluidSize = .default,
         skipLabel: String = "Skip", embedded: Bool,
         index: Binding<Int>? = nil,
         answers: Binding<[String: FluidAskAnswer]>? = nil,
         onSkip: @escaping (String, Int) -> Void = { _, _ in },
         onComplete: @escaping ([String: FluidAskAnswer]) -> Void = { _ in }) {
        self.init(questions: questions, size: size, skipLabel: skipLabel,
                  index: index, answers: answers, onSkip: onSkip,
                  onComplete: onComplete)
        self.embedded = embedded
    }

    private var compact: Bool { size == .compact }
    private var cur: Int {
        get { index?.wrappedValue ?? fallbackIndex }
        nonmutating set { index?.wrappedValue = newValue; fallbackIndex = newValue }
    }
    private var answerMap: [String: FluidAskAnswer] {
        answers?.wrappedValue ?? fallbackAnswers
    }
    private var safeIndex: Int { max(0, min(cur, max(0, questions.count - 1))) }
    private var question: FluidAskQuestion? {
        questions.indices.contains(safeIndex) ? questions[safeIndex] : nil
    }
    private var isMulti: Bool { question?.multiSelect ?? false }
    private var isFreeText: Bool { question?.freeText ?? false }
    private var allowOther: Bool { !isFreeText && (question?.allowOther ?? false) }
    private var answer: FluidAskAnswer {
        guard let q = question else { return FluidAskAnswer() }
        return answerMap[q.id] ?? FluidAskAnswer()
    }
    private var otherIndex: Int { (question?.options.count ?? 0) }
    private var rowCount: Int { (question?.options.count ?? 0) + (allowOther ? 1 : 0) }

    private func writeAnswer(_ qid: String, _ mutate: (inout FluidAskAnswer) -> Void) {
        var a = answerMap[qid] ?? FluidAskAnswer()
        mutate(&a)
        if answers != nil {
            answers?.wrappedValue[qid] = a
        } else {
            fallbackAnswers[qid] = a
        }
    }

    private func goNext() {
        if safeIndex >= questions.count - 1 {
            completed = true
            onComplete(answerMap)
        } else {
            cur = safeIndex + 1
        }
    }

    private func selectSingle(_ oid: String) {
        guard let q = question else { return }
        writeAnswer(q.id) {
            $0.selectedIds = [oid]; $0.skipped = false
        }
        goNext()
    }

    private func toggleMulti(_ oid: String) {
        guard let q = question else { return }
        writeAnswer(q.id) {
            if $0.selectedIds.contains(oid) { $0.selectedIds.remove(oid) }
            else { $0.selectedIds.insert(oid) }
            $0.skipped = false
        }
    }

    private func submitOther() {
        guard let q = question else { return }
        let text = (answer.otherText ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        if q.freeText, let message = q.freeTextValidate?(text), message != nil {
            freeTextError = message
            return
        }
        freeTextError = nil
        writeAnswer(q.id) { $0.otherText = text; $0.skipped = false }
        goNext()
    }

    private func skip() {
        guard let q = question else { return }
        writeAnswer(q.id) { $0.skipped = true }
        onSkip(q.id, safeIndex)
        goNext()
    }

    private func back() { if safeIndex > 0 { cur = safeIndex - 1 } }

    // Footer visibility mirrors the source exactly.
    private var showBack: Bool { questions.count > 1 && safeIndex > 0 }
    private var showSkip: Bool { questions.count > 1 && (question?.skippable ?? true) }
    private var showSubmit: Bool { isMulti || isFreeText }
    private var showFooter: Bool { showBack || showSkip || showSubmit }

    // Selected option indices — feeds the merged bg-active blocks.
    private var selectedIndices: Set<Int> {
        guard let q = question else { return [] }
        var s = Set<Int>()
        for (i, o) in q.options.enumerated() where answer.selectedIds.contains(o.id) {
            s.insert(i)
        }
        if allowOther && !(answer.otherText ?? "").isEmpty { s.insert(otherIndex) }
        return s
    }

    var body: some View {
        if embedded, let q = question {
            embeddedBody(q)
        } else {
            cardBody
        }
    }

    /// The embedded presentation: question rows in the composer's
    /// attachment area; the composer editor is the Other/freeText field.
    private func embeddedBody(_ q: FluidAskQuestion) -> some View {
        FluidInputMessage(
            text: otherBinding(q),
            placeholder: q.otherPlaceholder ?? "Describe in your own words…",
            size: size,
            focus: $fieldFocused,
            // freeTextMultiline: Enter newlines; ⌘↵ commits.
            enterSends: !(q.freeText && q.freeTextMultiline),
            onCommandReturn: { commandReturn() },
            onSend: { _, _ in composerSend() },
            header: {
                VStack(alignment: .leading, spacing: 8) {
                    Text(q.title)
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundStyle(FluidTone.foreground)
                    if !isFreeText { rows(q) }
                }
                .padding(.horizontal, compact ? 10 : 12)
                .padding(.top, 4)
                if showFooter { footer }
            },
            trailing: { EmptyView() }
        )
        .frame(maxWidth: 520)
        .focused($cardFocused)
        .focusable()
        .background(
            FluidAskUserKeys(
                onKey: { e in handleLocalKey(e) },
                onOutsideClick: { armed = false; cardFocused = false },
                onInsideClick: { armed = true }
            )
            .allowsHitTesting(false)
        )
        .onChange(of: safeIndex) { _, _ in
            otherMultiline = false
            if isFreeText { fieldFocused = true }
        }
    }

    /// Composer send while embedded — the editor is the Other/freeText
    /// field: single + freeText submit the text; multi acts like Continue.
    private func composerSend() {
        if isMulti { commandReturn() } else { submitOther() }
    }

    private var cardBody: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Morphing Q/A region — content swaps, the card's height rides
            // the slow spring (the source animates a measured height;
            // SwiftUI animates the layout change itself).
            VStack(alignment: .leading, spacing: 8) {
                if let q = question {
                    Text(q.title)
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundStyle(FluidTone.foreground)

                    if isFreeText {
                        freeTextField(q)
                    } else {
                        rows(q)
                    }
                } else {
                    Text("No questions.")
                        .font(.system(size: 13))
                        .foregroundStyle(FluidTone.mutedForeground)
                }
            }
            .padding(.horizontal, compact ? 14 : 20)
            .padding(.bottom, showFooter ? 4 : (compact ? 8 : 10))
            .animation(FluidSpring.slow, value: safeIndex)

            if showFooter { footer }
        }
        .padding(.top, 20 - 8)
        .padding(.bottom, 20 - 10)
        .frame(maxWidth: 520)
        .background(
            RoundedRectangle(cornerRadius: FluidShape.rounded.container, style: .continuous)
                .fill(FluidTone.card)
        )
        .overlay(
            RoundedRectangle(cornerRadius: FluidShape.rounded.container, style: .continuous)
                .strokeBorder(FluidTone.border, lineWidth: 1)
        )
        .focused($cardFocused)
        .focusable()
        .background(
            FluidAskUserKeys(
                onKey: { e in handleLocalKey(e) },
                onOutsideClick: { armed = false; cardFocused = false },
                onInsideClick: { armed = true }
            )
            .allowsHitTesting(false)
        )
        .onChange(of: safeIndex) { _, _ in otherMultiline = false }
    }

    // MARK: - Option rows

    @ViewBuilder
    private func rows(_ q: FluidAskQuestion) -> some View {
        FluidContainer(hover: hover, radius: FluidShape.rounded.bg) {
            VStack(alignment: .leading, spacing: 0) {
                ForEach(Array(q.options.enumerated()), id: \.offset) { i, opt in
                    optionRow(q, i, opt)
                }
                // Embedded mode has no in-list Other field — the composer
                // editor below the rows is it (the digit still focuses it).
                if allowOther && !embedded { otherRow(q) }
            }
        }
        .background(alignment: .topLeading) {
            FluidSelectionBlocks(hover: hover, checked: selectedIndices)
        }
        .padding(.horizontal, compact ? -10 : -12)
    }

    private func optionRow(_ q: FluidAskQuestion, _ i: Int, _ opt: FluidAskOption) -> some View {
        let selected = answer.selectedIds.contains(opt.id)
        let lit = hover.activeIndex == i
        let showArrow = !isMulti && lit
        return Button {
            // Arm the card's logical focus — pointer clicks don't move
            // keyboard focus on macOS, so digit/⌘↵ shortcuts would leak to
            // whatever field last held first responder.
            armed = true
            cardFocused = true
            if isMulti { toggleMulti(opt.id) } else { selectSingle(opt.id) }
        } label: {
            HStack(alignment: q.stacked ? .firstTextBaseline : .center,
                   spacing: q.chipPosition == .left ? 8 : 12) {
                if q.chipPosition == .left { chip(i + 1, filled: selected) }
                bodyContent(q, opt, selected: selected, lit: lit)
                    .frame(maxWidth: .infinity, alignment: .leading)
                if q.chipPosition == .right {
                    chipSlot(i + 1, filled: selected, arrow: showArrow)
                } else if !isMulti {
                    arrowSlot(visible: showArrow)
                }
            }
            .padding(.leading, q.chipPosition == .left ? 6 : 12)
            .padding(.trailing, q.chipPosition == .left ? (isMulti ? 12 : 6) : 6)
            .padding(.vertical, q.stacked ? (compact ? 6 : 8) : (compact ? 4 : 6))
            .frame(minHeight: q.stacked ? (compact ? 48 : 56) : (compact ? 32 : 40),
                   alignment: .leading)
            .contentShape(Rectangle())
            .overlay(
                RoundedRectangle(cornerRadius: FluidShape.rounded.focusRing, style: .continuous)
                    .strokeBorder(FluidTone.focusRing, lineWidth: 1)
                    .padding(-2)
                    .opacity(focusedRow == i ? 1 : 0)
            )
        }
        .buttonStyle(.plain)
        .focused($focusedRow, equals: i)
        .fluidItem(i)
    }

    /// Title (medium → semibold when selected, width-stable twin) +
    /// optional description — inline or stacked.
    @ViewBuilder
    private func bodyContent(_ q: FluidAskQuestion, _ opt: FluidAskOption,
                             selected: Bool, lit: Bool) -> some View {
        if q.stacked {
            VStack(alignment: .leading, spacing: 2) {
                FluidRowLabel(label: opt.title, selected: selected,
                              lit: lit, size: size)
                if let d = opt.description {
                    Text(d)
                        .font(.system(size: compact ? 11 : 12))
                        .foregroundStyle(FluidTone.mutedForeground)
                }
            }
        } else {
            HStack(spacing: 0) {
                FluidRowLabel(label: opt.title, selected: selected,
                              lit: lit, size: size)
                if let d = opt.description {
                    Text(" \(d)")
                        .font(.system(size: size.text))
                        .foregroundStyle(FluidTone.mutedForeground)
                }
            }
        }
    }

    /// The 28×28 slot: number chip that yields to the submit arrow on hover
    /// (single-select, chip-on-right).
    private func chipSlot(_ n: Int, filled: Bool, arrow: Bool) -> some View {
        ZStack {
            chip(n, filled: filled)
                .opacity(arrow ? 0 : 1)
            arrowSlot(visible: arrow)
        }
        .frame(width: compact ? 24 : 28, height: compact ? 24 : 28)
        .animation(FluidSpring.fast, value: arrow)
    }

    private func arrowSlot(visible: Bool) -> some View {
        RoundedRectangle(cornerRadius: FluidShape.rounded.bg, style: .continuous)
            .fill(FluidTone.foreground)
            .overlay(FluidIcon("arrow.right", size: compact ? 12 : 14)
                .foregroundStyle(FluidTone.background))
            .frame(width: compact ? 24 : 28, height: compact ? 24 : 28)
            .scaleEffect(visible ? 1 : 0.6)
            .opacity(visible ? 1 : 0)
    }

    /// The numbered chip: plain digit (single) or bordered/filled square
    /// (multi). `filled` emboldens/inverts it.
    private func chip(_ n: Int, filled: Bool) -> some View {
        Text("\(n)")
            .font(.system(size: 11, weight: filled ? .semibold : .medium))
            .foregroundStyle(filled
                             ? (isMulti ? FluidTone.background : FluidTone.foreground)
                             : FluidTone.mutedForeground)
            .frame(width: compact ? 18 : 20, height: compact ? 18 : 20)
            .background(
                Group {
                    if isMulti && filled {
                        RoundedRectangle(cornerRadius: FluidShape.rounded.bg, style: .continuous)
                            .fill(FluidTone.foreground)
                    } else if isMulti {
                        RoundedRectangle(cornerRadius: FluidShape.rounded.bg, style: .continuous)
                            .strokeBorder(FluidTone.border, lineWidth: 1)
                    }
                }
            )
    }

    // MARK: - Other / freeText fields

    /// The appended "Something else" row — a growing single-line-start text
    /// field inside an option row. Filled state joins the merged blocks.
    private func otherRow(_ q: FluidAskQuestion) -> some View {
        let i = otherIndex
        let filled = !(answer.otherText ?? "").isEmpty
        let showArrow = !isMulti && filled && (fieldFocused || hover.activeIndex == i)
        return HStack(alignment: otherMultiline ? .firstTextBaseline : .center,
                      spacing: q.chipPosition == .left ? 8 : 12) {
            if q.chipPosition == .left { chip(i + 1, filled: filled) }
            ZStack(alignment: .topLeading) {
                FluidComposerEditor(
                    text: otherBinding(q),
                    focused: $fieldFocused,
                    fontSize: size.text + 1,
                    lineHeight: 18,
                    minLines: 1, maxLines: 8,
                    onSend: { if isMulti { } else { submitOther() } },
                    onTab: {}, onArrowDown: { }, onArrowUp: { }, onEscape: { },
                    onMultilineChange: { otherMultiline = $0 },
                    onCommandReturn: { commandReturn() }
                )
                if (answer.otherText ?? "").isEmpty {
                    Text(q.otherPlaceholder ?? "Describe in your own words…")
                        .font(.system(size: size.text + 1))
                        .foregroundStyle(FluidTone.mutedForeground)
                        .padding(8)
                        .allowsHitTesting(false)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            if q.chipPosition == .right {
                chipSlot(i + 1, filled: filled, arrow: showArrow)
            } else if !isMulti {
                arrowSlot(visible: showArrow)
            }
        }
        .padding(.leading, q.chipPosition == .left ? 6 : 12)
        .padding(.trailing, q.chipPosition == .left ? 12 : 6)
        .padding(.vertical, compact ? 4 : 6)
        .frame(minHeight: compact ? 32 : 40, alignment: .leading)
        .contentShape(Rectangle())
        .fluidItem(i)
    }

    /// freeText mode: the whole answer area is one growing field. Empty +
    /// at rest it is quiet; hover lightens; filled takes bg-active.
    private func freeTextField(_ q: FluidAskQuestion) -> some View {
        let filled = !(answer.otherText ?? "").isEmpty
        return ZStack(alignment: .topLeading) {
            FluidComposerEditor(
                text: otherBinding(q),
                focused: $fieldFocused,
                fontSize: size.text + 1,
                lineHeight: 18,
                minLines: q.freeTextMultiline ? 3 : 1, maxLines: 8,
                onSend: { if !q.freeTextMultiline { submitOther() } },
                onTab: {}, onArrowDown: {}, onArrowUp: {}, onEscape: {},
                onCommandReturn: { commandReturn() }
            )
            if (answer.otherText ?? "").isEmpty {
                Text(q.freeTextPlaceholder ?? "Type your answer…")
                    .font(.system(size: size.text + 1))
                    .foregroundStyle(FluidTone.mutedForeground)
                    .padding(8)
                    .allowsHitTesting(false)
            }
        }
        .frame(minHeight: q.freeTextMultiline ? 76 : (compact ? 32 : 40),
               alignment: .topLeading)
        .padding(.horizontal, compact ? -10 : -12)
        .padding(.vertical, compact ? 8 : 10)
        .background(
            RoundedRectangle(cornerRadius: FluidShape.rounded.bg, style: .continuous)
                .fill(filled ? FluidTone.active : .clear)
        )
        .overlay(
            RoundedRectangle(cornerRadius: FluidShape.rounded.bg, style: .continuous)
                .strokeBorder(fieldFocused ? FluidTone.border : .clear, lineWidth: 1)
        )
        .contentShape(Rectangle())
        .onTapGesture { fieldFocused = true }
    }

    private func otherBinding(_ q: FluidAskQuestion) -> Binding<String> {
        Binding(
            get: { answerMap[q.id]?.otherText ?? "" },
            set: { v in
                freeTextError = nil
                writeAnswer(q.id) { $0.otherText = v.isEmpty ? nil : v; $0.skipped = false }
            }
        )
    }

    // MARK: - Footer

    private var footer: some View {
        HStack(spacing: 8) {
            if showBack {
                FluidButton("Back", variant: .ghost, size: .compact,
                            leadingIcon: "arrow.left", action: back)
                    .transition(.scale(scale: 0.85).combined(with: .opacity))
            }
            if let err = freeTextError {
                Text(err)
                    .font(.system(size: 12))
                    .foregroundStyle(FluidTone.destructive)
                    .lineLimit(2)
                    .transition(.opacity)
            }
            Spacer(minLength: 0)
            if showSkip {
                FluidButton(skipLabel, variant: .ghost, size: .compact,
                            trailingIcon: "arrow.right", action: skip)
                    .transition(.scale(scale: 0.85).combined(with: .opacity))
            }
            if showSubmit {
                FluidButton(variant: .primary, size: .compact,
                            action: isFreeText ? submitOther : goNext) {
                    HStack(spacing: 6) {
                        Text(question?.nextLabel
                             ?? (safeIndex >= questions.count - 1 ? "Finish" : "Continue"))
                        shortcutCap("⌘↵", inverted: true)
                    }
                }
                .disabled(isFreeText
                          ? (answer.otherText ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                          : answer.selectedIds.isEmpty && (answer.otherText ?? "").isEmpty)
                .transition(.scale(scale: 0.85).combined(with: .opacity))
            }
        }
        .padding(.horizontal, compact ? 14 : 20)
        .padding(.top, 4)
        .padding(.bottom, compact ? 6 : 8)
        .animation(FluidSpring.fast, value: showBack)
        .animation(FluidSpring.fast, value: showSkip)
        .animation(FluidSpring.fast, value: showSubmit)
    }

    private func shortcutCap(_ s: String, inverted: Bool) -> some View {
        Text(s)
            .font(.system(size: 11))
            .tracking(0.5)
            .padding(.horizontal, 4)
            .frame(minWidth: 18, minHeight: 18)
            .background(
                RoundedRectangle(cornerRadius: FluidShape.rounded.bg, style: .continuous)
                    .fill(inverted ? FluidTone.background.opacity(0.15)
                                   : FluidTone.foreground.opacity(0.1))
            )
            .foregroundStyle(inverted ? FluidTone.background
                                      : FluidTone.mutedForeground)
    }

    /// ⌘↵ — commits multi-select and freeText, gated on a real answer like
    /// the source's root handler. Reached through the card key handler or
    /// bubbled up from the editor (focus can sit in either place).
    private func commandReturn() {
        guard showSubmit, !completed else { return }
        if isFreeText { submitOther(); return }
        if !answer.selectedIds.isEmpty || !(answer.otherText ?? "").isEmpty {
            goNext()
        }
    }

    /// The armed keyDown path — mirrors `handleKey`, running while the card
    /// holds logical focus so shortcuts work even when AppKit never moved
    /// first responder. ⌘↵ fires even with the editor focused (the source
    /// bubbles it from the textarea to the root); everything else yields to
    /// the editor when it holds first responder.
    private func handleLocalKey(_ e: NSEvent) -> NSEvent? {
        let flags = e.modifierFlags.intersection([.shift, .command, .control, .option])
        if e.keyCode == 36, flags == .command, armed || cardFocused || fieldFocused {
            commandReturn(); return nil
        }
        guard (armed || cardFocused), !fieldFocused, !completed else { return e }
        switch e.keyCode {
        case 123 where flags.isEmpty: back(); return nil          // ←
        case 124 where flags.isEmpty:                             // →
            if showSkip { skip(); return nil }
            return e
        case 125 where flags.isEmpty:                             // ↓
            guard rowCount > 0 else { return e }
            hover.activeIndex = ((hover.activeIndex ?? -1) + 1) % rowCount
            return nil
        case 126 where flags.isEmpty:                             // ↑
            guard rowCount > 0 else { return e }
            hover.activeIndex = ((hover.activeIndex ?? 0) - 1 + rowCount) % rowCount
            return nil
        default: break
        }
        if flags.isEmpty, !isFreeText,
           let d = e.charactersIgnoringModifiers?.first.flatMap({ Int(String($0)) }),
           (1...9).contains(d), let q = question {
            let idx = d - 1
            if idx < q.options.count {
                let oid = q.options[idx].id
                if isMulti { toggleMulti(oid) } else { selectSingle(oid) }
                return nil
            }
            if idx == q.options.count, allowOther {
                fieldFocused = true
                return nil
            }
        }
        return e
    }
}

// MARK: - Card key probe

/// An invisible NSView spanning the card that installs local key/mouse
/// monitors while attached to the window. The source scopes shortcuts to
/// the card holding DOM focus; AppKit clicks don't move first responder,
/// so the card's logical focus (`armed`) is what these monitors serve.
private struct FluidAskUserKeys: NSViewRepresentable {
    var onKey: (NSEvent) -> NSEvent?
    var onOutsideClick: () -> Void
    var onInsideClick: () -> Void = {}

    func makeNSView(context: Context) -> FluidKeyProbeView { FluidKeyProbeView() }
    func updateNSView(_ v: FluidKeyProbeView, context: Context) {
        v.onKey = onKey
        v.onOutsideClick = onOutsideClick
        v.onInsideClick = onInsideClick
    }
}

private final class FluidKeyProbeView: NSView {
    var onKey: ((NSEvent) -> NSEvent?)?
    var onOutsideClick: (() -> Void)?
    var onInsideClick: (() -> Void)?
    private var keyMonitor: Any?
    private var clickMonitor: Any?

    /// First ancestor with real bounds — the zero-size probe's immediate
    /// superview is also zero-size, so inside/outside checks need the
    /// enclosing card view.
    private var card: NSView? {
        var v: NSView? = self
        while let next = v?.superview, next.bounds.size == .zero { v = next }
        return v?.superview ?? v
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window != nil {
            if keyMonitor == nil {
                keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] e in
                    guard let self, e.window === self.window else { return e }
                    return self.onKey?(e) ?? e
                }
            }
            if clickMonitor == nil {
                clickMonitor = NSEvent.addLocalMonitorForEvents(
                    matching: [.leftMouseDown, .rightMouseDown]
                ) { [weak self] e in
                    guard let self, e.window === self.window,
                          let card = self.card else { return e }
                    let p = card.convert(e.locationInWindow, from: nil)
                    if card.bounds.contains(p) { self.onInsideClick?() }
                    else { self.onOutsideClick?() }
                    return e
                }
            }
        } else {
            if let m = keyMonitor { NSEvent.removeMonitor(m); keyMonitor = nil }
            if let m = clickMonitor { NSEvent.removeMonitor(m); clickMonitor = nil }
        }
    }

    deinit {
        if let m = keyMonitor { NSEvent.removeMonitor(m) }
        if let m = clickMonitor { NSEvent.removeMonitor(m) }
    }
}

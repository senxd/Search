# Ask — chat UX

The small affordances around the conversation: copying what a turn
produced, the composer's readout of what the *next* turn brings and is
allowed, and the little meta a message keeps. All of it draws in
AskUI.swift; Mind owns what state there is.

## Copying

Every copy is two lines of AppKit — `NSPasteboard.general.clearContents()`
then `setString(_, forType: .string)`, the way `Browser.copyAddress` and
ImageMenu already do it — gathered into one helper on the private `AskUI`
enum:

    static func copy(_ text: String)

`message.text` is plain — `Text` never renders markdown — so copy writes it
verbatim; there is no source-vs-rendered choice to make. ⌘C on a selection
keeps working (`.textSelection(.enabled)` stays) — that is the keyboard
story; nothing new is bound.

- **Message** — `AskLine` gains `@State hovering` (`.onHover`,
  `Motion.quick`, like ChatRow). On hover a `CopyChip` — 9pt `doc.on.doc`
  in a ground-filled, hairline-stroked capsule 14pt tall — floats in the
  LazyVStack's 14pt gap beneath the message:
  `.overlay(alignment: .bottomLeading)` for agent, `.bottomTrailing` for
  you, `.offset(y: 13)` so it sits in the gap while its top edge still
  overlaps the message by a point — the pointer reaches it without the
  row's hover ending (the chip carries its own `.onHover` into the same
  flag). No layout shift; it copies `message.text` and swaps to
  `checkmark` for ~0.8s. Hidden when `text` is empty — a tools-only
  message leaves copying to its rows. A `.contextMenu { Button("Copy") }`
  on you/agent lines covers right-click.
- **Tool card** — `ToolRow` already ends in `Spacer` (AskUI.swift:597):
  the trailing slot a TabCard's cross uses. On row-hover a 9pt `doc.on.doc`
  fades in there; nothing is reserved, the spacer holds the space.
  Payload: `"\(name) \(args)\n→ \(result ?? "(no result)")"` — the full
  strings, not the one-lined `detail`, so it pastes into a bug. A running
  card copies name + args only.
- **Whole chat** — `ChatRow.contextMenu` gains "Copy Transcript" above
  Delete → `AskUI.transcript(_ chat: AskChat) -> String`:

      You: <text>            · <tab title> (<host>)   per attachment
      Agent: <text>
        • name args → result        (AskUI.oneline — shape, not payload)
      — <note text>

Deferred: per-fenced-block copy — message copy carries the fences
verbatim already; a block parser buys a marginal reach.

## Composer chips

The card reads top to bottom: what the next turn may touch (above the
field), the words, then what answers it and under what leash (below).
Two chip rows, one job each — never mixed.

**Above** — the existing `chips` section keeps the consent chips and gains
a suggestion: when `browser.active` has an `address`, isn't `.bench` (the
agent's own tabs need no chip), and isn't already in `mind.context`, the
row ends with a dimmed capsule — `Mark(dim: true)`, `"+ \(label)"` capped
at 18 chars like `Chip`, `Palette.faint` ink on `Palette.ground`,
dashed hairline (`strokeBorder(style: StrokeStyle(dash: [3, 2]))`) —
`.help("Hand this page to the agent")`. Clicking appends the AskTab:
factor `attach(_:)` into `chip(_:)` (the append) which `attach` wraps
with the "@" draft-strip. The section shows when
`!mind.context.isEmpty || suggested != nil`. Codex attaches cwd
implicitly; our cwd is the active tab — suggested, never auto-attached,
because the chip *is* the consent.

**Below** — the footer line is repurposed as `status`,
`HStack(spacing: 6)`, same paddings:

- `ModelMenu` — unchanged; the capsule label already is a chip, and the
  chip is the menu. (Header's `short` one stays — it's the chat's model
  readout while the list is up.)
- `ModeMenu` — new twin of `ModelMenu`: a `Menu` with the same capsule
  label (10pt medium, `Palette.ground.opacity(0.6)` fill, hairline,
  hidden indicator). It draws whatever the permissions design lands — the
  contract here is only `label: String` ("Read"/"Guard"/"Full") plus a
  menu of modes; the chip doesn't know the semantics. Factor the shared
  capsule into `StatusChip(text:)` both menus use as `label:`.
- Nothing else. While `mind.running` the stream's activity line and the
  stop button already say so — this row stays scoped to the *next* turn,
  which is also why the mode chip belongs here and not in the header.

The "@" hint text leaves with the footer — the field's placeholder
("@ for context") and the empty state already teach it. Truncation:
model id `.truncationMode(.middle)`, `frame(maxWidth: 170)`; mode labels
are short; suggestion caps at 18 chars like `Chip`.

## Message meta

One set, worn inside the same hover chip for `you` and `agent` —
`HStack(spacing: 6) { CopyChip; Text(ago); Text(model) }`, all 9.5pt
`Palette.faint`:

- **when** — `AskUI.ago(message.when)`. The field already exists;
  hovering is how you ask for it.
- **which model** — `AskMessage` gains `var model: String? = nil`
  (optional → old chats decode nil). Stamped in `Mind.hear(.message)`:
  `m.model = m.model ?? chats[at].model` — no harness.js change. For that
  stamp to be the answering model, `Mind.send` must set
  `chat.model = model.id` every turn (today only at creation, so a
  mid-chat switch never reaches the chat — harness.js reads
  `job.chat.model`). Shown only when the chat mixes models:
  `Set(messages.compactMap(\.model)).count > 1`, computed once in
  `conversation` and passed to `AskLine` as `mixed`; the caption is the
  id's model tail ("z-ai/glm-5.3-flash"), not the provider.
- **forked/retried** — none drawn here. interaction.md writes them as
  `.note` lines; `.note` keeps its centred-quiet rendering untouched.

## Edges

- The gap chip overlaps the message above by a point and holds its own
  `.onHover` — no dead pixel between line and chip.
- `.note` lines get no meta and no copy — they're chrome already.
- Copying mid-stream snapshots the text as it stands — fine.
- Chips attached while `mind.running` wait for the next `send` — `steer`
  carries no attachments. The suggestion stays live meanwhile.
- `ModeMenu` before permissions land: bind it to the chat's mode defaulting
  to guard; the slot is drawn either way.

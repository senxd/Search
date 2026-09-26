import SwiftUI

// Tab groups: a named, coloured run of tabs that stays together in the row.
// Folded, a group is a chip standing where its first member sits; open, its
// tabs follow the chip in place. Two rules hold everywhere and are kept by
// `move` rather than by trust: a group is always one unbroken run, and a
// pinned tab is never in one — a pin is already a place kept for a page,
// which is all a group is.
//
// This file is the model; the logic is the "tab groups" extension on
// Browser, and `visibleItems` there is the flattened list both tab rows
// will iterate — a chip where a group's first member sits, then its tabs.

/// A named, coloured set of tabs that stays together in the row.
struct TabGroup: Codable, Equatable, Identifiable {
    var id = UUID()
    /// nil until named; shown as "Group N" by position among unnamed groups.
    var name: String?
    /// Index into `Groups.colours`.
    var colour: Int
    /// SF Symbol name from `Groups.icons`; default at creation.
    var icon: String
    /// Expanded shows member tabs; collapsed shows only the header/chip.
    var expanded = true

    /// The colour it wears, tolerant of a file written against a longer
    /// palette — out of range reads as grey rather than crashing the row.
    var tint: Color {
        Groups.colours.indices.contains(colour) ? Groups.colours[colour] : Groups.colours[0]
    }

    /// The symbol it wears, falling back to the default when the file names
    /// one the list doesn't have.
    var symbol: String { Groups.icons.contains(icon) ? icon : "folder" }
}

/// A group closed whole, for the ghost that can bring it back: what it was
/// called and wore, and its members as session entries, in row order.
struct ClosedGroup: Equatable {
    var group: TabGroup
    var entries: [Session.Entry]
}

/// One thing in the flattened row both tab bars draw: a group's chip, or a
/// tab. The chip stands at the first member's place; while the group is
/// folded it is all the members contribute.
enum TabItem: Identifiable {
    case group(TabGroup)
    case tab(Tab)

    var id: String {
        switch self {
        case .group(let group): return "group-\(group.id.uuidString)"
        case .tab(let tab): return "tab-\(tab.id.uuidString)"
        }
    }

    var tab: Tab? {
        guard case .tab(let tab) = self else { return nil }
        return tab
    }

    var group: TabGroup? {
        guard case .group(let group) = self else { return nil }
        return group
    }
}

/// What a group can wear: eight muted colours in a fixed order, so `colour`
/// is a stable index into the list, and a set of symbols broad enough that
/// a group is more often about something than not.
enum Groups {
    /// Arc- and Dia-like dots, mid-weight so they read on the window's
    /// ground in either look — neither washed out on white nor loud on dark.
    static let colours: [Color] = [
        Color(red: 0.604, green: 0.604, blue: 0.604), // grey    #9a9a9a
        Color(red: 0.878, green: 0.376, blue: 0.435), // red     #e0606f
        Color(red: 0.878, green: 0.541, blue: 0.290), // orange  #e08a4a
        Color(red: 0.851, green: 0.694, blue: 0.231), // yellow  #d9b13b
        Color(red: 0.310, green: 0.682, blue: 0.431), // green   #4fae6e
        Color(red: 0.357, green: 0.553, blue: 0.937), // blue    #5b8def
        Color(red: 0.608, green: 0.427, blue: 0.839), // purple  #9b6dd6
        Color(red: 0.820, green: 0.388, blue: 0.659), // magenta #d163a8
    ]
    static let colourNames = ["Grey", "Red", "Orange", "Yellow", "Green", "Blue", "Purple", "Magenta"]

    /// The symbols a group can wear — Apple's own, drawn in one weight —
    /// ordered as keeping, work, thinking, writing, life and play. `folder`
    /// leads because it is what a group wears until you say otherwise.
    static let icons = [
        "folder", "bookmark", "star", "heart", "flag", "tag",
        "briefcase", "building.2", "laptopcomputer", "desktopcomputer", "terminal", "chevron.left.forwardslash.chevron.right",
        "brain.head.profile", "lightbulb", "sparkles", "bolt", "wrench", "hammer",
        "book", "newspaper", "envelope", "bubble.left", "phone", "globe", "map",
        "lock.shield", "house", "graduationcap", "cart", "gift", "shippingbox",
        "music.note", "film", "camera", "paintpalette", "gamecontroller", "trophy",
        "cup.and.saucer", "beach.umbrella", "dumbbell", "figure.run", "airplane",
        "leaf", "pawprint", "sun.max", "moon", "cloud", "snowflake", "flame",
    ]
    static let iconNames = [
        "Folder", "Bookmark", "Star", "Personal", "Flag", "Tag",
        "Work", "Office", "Laptop", "Desktop", "Terminal", "Code",
        "Thinking", "Ideas", "AI", "Bolt", "Wrench", "Hammer",
        "Reading", "News", "Mail", "Chat", "Phone", "Web", "Places",
        "Security", "Home", "Studies", "Shopping", "Gift", "Package",
        "Music", "Film", "Photos", "Art", "Games", "Trophy",
        "Café", "Leisure", "Sport", "Running", "Travel",
        "Nature", "Pets", "Sun", "Moon", "Cloud", "Snow", "Flame",
    ]
}

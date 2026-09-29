import SwiftUI

// The app's own pages — Settings, History, Downloads, Bookmarks, Passwords.
// They live at search:// addresses so tabs, the session, the address field
// and Back/Forward all treat them like any other page: one kind of thing,
// one way to open it, one way to close it.
//
// A `search://` tab never loads: `Tab.go` sets the address and stops there,
// and `Page`'s place in the stage is taken by NativePageView. The panels
// these used to float over the page are the same views, just spread out to
// fill it — the sheet chrome is gone, a page needs no Done button.

/// Which of the app's pages an address names, or nothing for the web.
enum NativePage: String, CaseIterable, Identifiable {
    case settings, history, downloads, bookmarks, passwords

    var id: String { rawValue }

    init?(url: URL) {
        guard url.scheme == "search" else { return nil }
        self.init(rawValue: url.host ?? "")
    }

    var url: URL { URL(string: "search://\(rawValue)")! }

    var title: String {
        switch self {
        case .settings: return "Settings"
        case .history: return "History"
        case .downloads: return "Downloads"
        case .bookmarks: return "Bookmarks"
        case .passwords: return "Passwords"
        }
    }

    /// The tab's mark — these pages have no favicon to fetch.
    var icon: String {
        switch self {
        case .settings: return "gearshape"
        case .history: return "clock"
        case .downloads: return "arrow.down.circle"
        case .bookmarks: return "bookmark"
        case .passwords: return "key"
        }
    }
}

/// "Settings › Ask" — a page that is already open hears the section asked
/// for and shows it, rather than a second Settings tab answering instead.
extension Notification.Name {
    static let nativePageSection = Notification.Name("search.nativePageSection")
}

/// The page, filling the stage where a web view would be. Each one keeps
/// its panel's content; the sheet's plate and cross are what went away.
struct NativePageView: View {
    let page: NativePage
    @ObservedObject var browser: Browser

    var body: some View {
        Group {
            switch page {
            case .settings: SettingsPage(browser: browser, prefs: browser.prefs)
            case .history: HistoryPage(browser: browser)
            case .downloads: DownloadsPage(browser: browser, loot: browser.loot)
            case .bookmarks: BookmarksPage(browser: browser, bookmarks: browser.bookmarks)
            case .passwords: PasswordsPage(browser: browser)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Palette.ground)
        .transition(.opacity)
    }
}

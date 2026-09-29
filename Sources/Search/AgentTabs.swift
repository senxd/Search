import SwiftUI

struct AgentTabIndicator: View {
    var body: some View {
        Image(systemName: "flask")
            .font(.system(size: 8))
            .foregroundStyle(Palette.muted)
            .help("Kept from an agent")
            .accessibilityLabel("Kept from an agent")
    }
}

struct AgentTabsButton: View {
    @ObservedObject var browser: Browser
    var edge: Edge = .bottom
    @State private var showing = false
    @State private var hovering = false

    var body: some View {
        if !browser.agentTabs.isEmpty {
            Button { showing.toggle() } label: {
                HStack(spacing: 4) {
                    Image(systemName: "flask")
                    Text("\(browser.agentTabs.count)").monospacedDigit()
                    Image(systemName: "chevron.down").font(.system(size: 8))
                }
                .font(.system(size: 11))
                .foregroundStyle(browser.active?.bench == true ? Palette.ink : Palette.muted)
                .padding(.horizontal, 7)
                .frame(height: 26)
                .background(RoundedRectangle(cornerRadius: 8).fill(hovering || showing ? Palette.hover : .clear))
            }
            .buttonStyle(.plain)
            .onHover { hovering = $0 }
            .help("Agent tabs")
            .accessibilityLabel("Agent tabs, \(browser.agentTabs.count) open")
            .popover(isPresented: $showing, arrowEdge: edge) {
                AgentTabsDropdown(browser: browser) { showing = false }
            }
            .onChange(of: browser.spaceID) { _, _ in showing = false }
        }
    }
}

private struct AgentTabsDropdown: View {
    @ObservedObject var browser: Browser
    let dismiss: () -> Void

    private var groups: [(id: String, title: String, tabs: [Tab])] {
        var result: [(id: String, title: String, tabs: [Tab])] = []
        for tab in browser.agentTabs {
            let key = tab.agentGroup ?? tab.agentName ?? "agent"
            if let index = result.firstIndex(where: { $0.id == key }) {
                result[index].tabs.append(tab)
            } else {
                result.append((key, tab.agentName ?? "Agent tabs", [tab]))
            }
        }
        return result
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 4) {
                    ForEach(groups, id: \.id) { group in
                        HStack {
                            Text(group.title)
                            Spacer()
                            Text("\(group.tabs.count)").monospacedDigit()
                        }
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(Palette.muted)
                        .padding(.horizontal, 8)
                        .padding(.top, 6)
                        ForEach(group.tabs) { tab in
                            AgentTabRow(browser: browser, tab: tab, dismiss: dismiss)
                        }
                    }
                }
                .padding(6)
            }
            .frame(maxHeight: 360)
            Divider().overlay(Palette.hairline)
            Button("Close all agent tabs", role: .destructive) {
                for tab in browser.agentTabs { browser.close(tab) }
                dismiss()
            }
            .buttonStyle(.plain)
            .font(.system(size: 12))
            .foregroundStyle(Palette.muted)
            .padding(12)
        }
        .frame(width: 340)
        .background(Palette.ground)
    }
}

private struct AgentTabRow: View {
    @ObservedObject var browser: Browser
    @ObservedObject var tab: Tab
    let dismiss: () -> Void
    @State private var hovering = false

    var body: some View {
        HStack(spacing: 6) {
            Button {
                browser.select(tab)
                dismiss()
            } label: {
                HStack(spacing: 8) {
                    Mark(icon: tab.icon, letter: tab.monogram, size: 15)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(tab.label).foregroundStyle(Palette.ink)
                        if let address = tab.address {
                            Text(address.host() ?? Address.pretty(address))
                                .font(.system(size: 11))
                                .foregroundStyle(Palette.muted)
                        }
                    }
                    .lineLimit(1)
                    Spacer(minLength: 0)
                    if tab.id == browser.activeID {
                        Image(systemName: "checkmark").foregroundStyle(Palette.muted)
                    }
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("View \(tab.label)")
            Button("Keep") {
                browser.surfaceAgentTab(tab)
                dismiss()
            }
            .buttonStyle(.borderless)
            .help("Show as a normal tab and keep its current page")
            .accessibilityLabel("Keep \(tab.label) as a normal tab")
            Button {
                browser.close(tab)
                if browser.agentTabs.isEmpty { dismiss() }
            } label: {
                Image(systemName: "xmark").font(.system(size: 10))
            }
            .buttonStyle(.plain)
            .foregroundStyle(Palette.muted)
            .help("Close tab")
            .accessibilityLabel("Close \(tab.label)")
        }
        .font(.system(size: 12.5))
        .padding(8)
        .background(RoundedRectangle(cornerRadius: 8).fill(hovering || tab.id == browser.activeID ? Palette.wash : .clear))
        .onHover { hovering = $0 }
    }
}

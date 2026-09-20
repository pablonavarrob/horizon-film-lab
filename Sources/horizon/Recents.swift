import SwiftUI

// ============================== DEV-RECENT ==============================
// Recently opened rolls, in the machine's own order-list idiom: a teal caption
// bar over a sunken white field, numbered rows, alternating row tint.
//
// Recorded in ONE place, `RollStore.accept(_:)`, because that is the single
// funnel every route already goes through -- Open Roll, New Roll and the
// drag-and-drop handler all call it. Hook anywhere else and one of the three
// silently stops recording.
//
// Paths, not bookmarks: the app is not sandboxed, so a path is enough. If it is
// ever sandboxed this needs NSURL bookmark data, and so does drag-and-drop.
//
// TO REMOVE: grep DEV-RECENT. This file, the `recents` property and its call in
// `accept`, the `RecentRolls` row in ContentView's EmptyState, and the Open
// Recent submenu in main.swift.
// =======================================================================

extension RollStore {
    private nonisolated static let recentsKey = "recentRolls"
    /// Eight fits the panel without scrolling. A convenience, not an archive.
    private nonisolated static let recentsMax = 8

    /// Folders opened before, newest first, filtered to ones still on disk.
    ///
    /// `nonisolated` because the File menu is built before the actor exists;
    /// UserDefaults and FileManager are both safe off the main actor. Filtered on
    /// READ, not pruned on write, so a folder on an unmounted volume comes back
    /// when it is mounted again rather than being forgotten.
    /// PRUNES AS IT READS. It filtered dead paths out of the returned list but
    /// left them in storage, so they accumulated forever and any consumer reading
    /// UserDefaults directly still saw them.
    nonisolated static func loadRecents() -> [URL] {
        let stored = UserDefaults.standard.stringArray(forKey: recentsKey) ?? []
        let live = stored.filter { FileManager.default.fileExists(atPath: $0) }
        if live.count != stored.count {
            UserDefaults.standard.set(live, forKey: recentsKey)
        }
        return live.map { URL(fileURLWithPath: $0) }
    }

    /// Drop one roll from the list, by resolved path so it matches however the
    /// folder was reached. Used when an entry turns out to be gone.
    nonisolated static func forgetRecent(_ dir: URL) {
        let key = dir.standardizedFileURL.resolvingSymlinksInPath().path
        let kept = (UserDefaults.standard.stringArray(forKey: recentsKey) ?? [])
            .filter { URL(fileURLWithPath: $0).standardizedFileURL
                          .resolvingSymlinksInPath().path != key }
        UserDefaults.standard.set(kept, forKey: recentsKey)
    }

    /// Newest first, de-duplicated by resolved path so the same folder reached
    /// two ways -- dropped once, picked once -- does not appear twice.
    func recordRecent(_ dir: URL) {
        let key = dir.standardizedFileURL.resolvingSymlinksInPath().path
        var paths = UserDefaults.standard.stringArray(forKey: Self.recentsKey) ?? []
        paths.removeAll {
            URL(fileURLWithPath: $0).standardizedFileURL
                .resolvingSymlinksInPath().path == key
        }
        paths.insert(key, at: 0)
        UserDefaults.standard.set(Array(paths.prefix(Self.recentsMax)), forKey: Self.recentsKey)
        recents = Self.loadRecents()
    }
}

/// The idle window's recent list. Always present, empty or not: the machine's
/// order list is a fixture of the screen, and a panel that appears from nowhere
/// on the second launch reads as a glitch.
struct RecentRolls: View {
    @ObservedObject var store: RollStore

    var body: some View {
        VStack(spacing: 0) {
            // Caption bar, as on every list panel in the machine.
            HStack(spacing: 6) {
                Text("RECENT ORDERS")
                    .font(FUI.label(true))
                    .foregroundStyle(.white)
                Spacer()
                Text("\(store.recents.count)")
                    .font(FUI.small())
                    .foregroundStyle(.white.opacity(0.75))
            }
            .padding(.horizontal, 8)
            .frame(height: 20)
            .background(FUI.tealRule)

            if store.recents.isEmpty {
                Text("no orders yet")
                    .font(FUI.small())
                    .foregroundStyle(FUI.ink.opacity(0.4))
                    .frame(height: 22)
                    .frame(maxWidth: .infinity)
                    .background(Color.white)
            } else {
                ForEach(Array(store.recents.enumerated()), id: \.element) { i, url in
                    Row(index: i + 1, url: url, store: store)
                        .background(i % 2 == 0 ? Color.white : FUI.hex(0xF0F0F0))
                }
            }
        }
        .frame(width: 420)
        .overlay(Rectangle().strokeBorder(FUI.outline.opacity(0.55), lineWidth: 1))
        .bevel(up: false)
    }

    private struct Row: View {
        let index: Int
        let url: URL
        @ObservedObject var store: RollStore
        @State private var hot = false

        /// Home abbreviated, and only the containing folder kept. The full path
        /// of a scan folder is long enough to push the name off the row, and the
        /// name is the part being recognised.
        private var where_: String {
            let parent = url.deletingLastPathComponent().path
            let home = FileManager.default.homeDirectoryForCurrentUser.path
            return parent.hasPrefix(home)
                ? "~" + parent.dropFirst(home.count) : parent
        }

        var body: some View {
            Button { store.accept(url) } label: {
                HStack(spacing: 8) {
                    Text("\(index)")
                        .font(FUI.small())
                        .foregroundStyle(FUI.ink.opacity(0.5))
                        .frame(width: 14, alignment: .trailing)
                    Text(url.lastPathComponent)
                        .font(FUI.label())
                        .foregroundStyle(FUI.ink)
                        .lineLimit(1)
                    Spacer(minLength: 8)
                    Text(where_)
                        .font(FUI.small())
                        .foregroundStyle(FUI.ink.opacity(0.45))
                        .lineLimit(1)
                        .truncationMode(.head)
                }
                .padding(.horizontal, 8)
                .frame(height: 22)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .background(hot ? FUI.tealRule.opacity(0.12) : .clear)
            .onHover { hot = $0 }
        }
    }
}

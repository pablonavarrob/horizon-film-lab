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

/// A read-only snapshot for one recent roll. Loading never creates a workspace
/// or metadata sidecar; a corrupt sidecar stays untouched and is represented as
/// unavailable so the list cannot mistake it for newly empty metadata.
struct RecentRoll: Identifiable {
    let url: URL
    let id: String
    let metadata: RollMetadata?
    let metadataIssue: String?

    var title: String {
        url.lastPathComponent
    }

    var subtitle: String {
        if metadataIssue != nil { return "Metadata unavailable" }
        return metadata?.recentOrderSummary ?? ""
    }

    var tooltip: String {
        var lines = [url.path]
        if let metadata {
            let fields: [(String, String)] = [
                ("Title", metadata.title), ("Stock", metadata.stock),
                ("Format", metadata.format), ("Box ISO", metadata.boxISO),
                ("Shooting EI", metadata.shootingEI), ("Camera", metadata.filmCamera),
                ("Lens", metadata.filmLens), ("Photographic date", metadata.photographDate),
                ("Location", metadata.location), ("Development", metadata.developmentNotes)
            ]
            lines += fields.compactMap { label, value in
                let value = value.trimmingCharacters(in: .whitespacesAndNewlines)
                return value.isEmpty ? nil : "\(label): \(value)"
            }
            if fields.allSatisfy({ $0.1.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }) {
                lines.append("No photographic metadata recorded")
            }
        } else if let metadataIssue {
            lines.append("Metadata unavailable: \(metadataIssue)")
        } else {
            lines.append("No photographic metadata recorded")
        }
        return lines.joined(separator: "\n")
    }

    init(url: URL) {
        self.url = url
        id = url.standardizedFileURL.resolvingSymlinksInPath().path
        let metadataURL = Workspace(anyOf: url).metadata
        guard FileManager.default.fileExists(atPath: metadataURL.path) else {
            metadata = nil
            metadataIssue = nil
            return
        }
        do {
            metadata = try RollPersistence.loadMetadata(from: metadataURL)
            metadataIssue = nil
        } catch {
            metadata = nil
            metadataIssue = error.localizedDescription
        }
    }
}

extension RollStore {
    private nonisolated static let recentsKey = "recentRolls"
    /// Keep eight recent orders; the panel scrolls after five visible rows.
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

    /// Recent list snapshots keep metadata reads out of SwiftUI body updates.
    nonisolated static func loadRecentOrders() -> [RecentRoll] {
        loadRecents().map(RecentRoll.init(url:))
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
        refreshRecents()
    }

    func refreshRecents() {
        recents = Self.loadRecentOrders()
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
                ScrollView(.vertical) {
                    LazyVStack(spacing: 0) {
                        ForEach(Array(store.recents.enumerated()), id: \.element.id) { i, roll in
                            Row(index: i + 1, roll: roll, store: store)
                                .background(i % 2 == 0 ? Color.white : FUI.hex(0xF0F0F0))
                        }
                    }
                }
                .frame(height: CGFloat(min(store.recents.count, 5) * 32))
            }
        }
        .frame(width: 560)
        .overlay(Rectangle().strokeBorder(FUI.outline.opacity(0.55), lineWidth: 1))
        .bevel(up: false)
        .onAppear { store.refreshRecents() }
    }

    private struct Row: View {
        let index: Int
        let roll: RecentRoll
        @ObservedObject var store: RollStore
        @State private var hot = false

        var body: some View {
            HStack(spacing: 8) {
                Button { store.accept(roll.url) } label: {
                    HStack(spacing: 6) {
                        Text("\(index)")
                            .font(FUI.small())
                            .foregroundStyle(FUI.ink.opacity(0.5))
                            .frame(width: 14, alignment: .trailing)
                        Text(roll.title)
                            .font(FUI.label())
                            .foregroundStyle(FUI.ink)
                            .lineLimit(1)
                            .layoutPriority(1)
                        if !roll.subtitle.isEmpty {
                            Text("·")
                                .font(FUI.small())
                                .foregroundStyle(FUI.ink.opacity(0.38))
                            Text(roll.subtitle)
                                .font(FUI.small())
                                .foregroundStyle(FUI.ink.opacity(0.5))
                                .lineLimit(1)
                                .truncationMode(.tail)
                                .help(roll.subtitle)
                        }
                        Spacer(minLength: 0)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help(roll.tooltip)

                Button { store.editRecentMetadata(roll.url) } label: {
                    Image(systemName: "pencil")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(FUI.ink.opacity(0.65))
                        .frame(width: 22, height: 24)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Edit metadata for \(roll.title)")
                .disabled(!store.canEditRecentMetadata)
                .help("Edit photographic metadata")
            }
            .padding(.horizontal, 8)
            .frame(height: 32)
            .background(hot ? FUI.tealRule.opacity(0.12) : .clear)
            .onHover { hot = $0 }
        }
    }
}

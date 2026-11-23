import DeviceCore
import Foundation
import Observation
import os

private let listingLog = Logger(subsystem: WorkNames.subsystem, category: "listing")

enum SortKey: String, Hashable {
    case name, size, modified, kind
}

/// A place in a window's history: which device and which folder.
struct HistoryEntry: Hashable {
    let deviceID: String
    let path: String
}

struct BrowserSort: Hashable {
    var key: SortKey = .name
    var ascending = true
}

/// One window's view of a device: location, history, listing, selection.
/// The file system is attached/detached as the device connects, keeping the location so a
/// reconnect lands where the user was.
@MainActor @Observable
final class BrowserModel {
    private(set) var fileSystem: (any DeviceFileSystem)?
    private(set) var location: RemoteRef?
    private(set) var visibleEntries: [RemoteEntry] = []
    private(set) var isLoading = false
    private(set) var error: String?
    private(set) var loadedCount = 0
    /// The last listing failed because the connection dropped (e.g. unplugged): show
    /// "checking the connection" rather than an error while the device catches up.
    private(set) var connectionLost = false
    /// When the current listing started (for waiting feedback).
    private(set) var loadStarted: Date?
    /// Names are listed; sizes and dates are still arriving.
    private(set) var detailsPending = false
    private var generation = 0
    /// Told when a folder can't be opened (e.g. a favorite that was deleted on the phone).
    var onLoadFailure: ((String) -> Void)?
    /// A listing found the connection gone or not answering.
    var onConnectionLost: ((any DeviceFileSystem) -> Void)?
    /// Told after a rename / delete, with the device it was done on (the window may have moved
    /// to another device by the time a slow one finishes).
    var onRenamed: ((_ deviceID: String?, _ old: String, _ new: String) -> Void)?
    var onDeleted: ((_ deviceID: String?, _ paths: [String]) -> Void)?

    /// A failed file operation, shown as an alert.
    var operationError: String?
    /// Entry to put into inline rename mode once it's on screen (set after "New Folder").
    var renamingID: String?
    private var pendingRename = false
    var selection = Set<String>()

    /// Sort by size/date is requested but waits for the details.
    var sortIsDeferred: Bool { detailsPending && (sort.key == .size || sort.key == .modified) }

    var sort = BrowserSort() {
        didSet { if sort != oldValue { refreshVisible() } }
    }

    /// One setting for every window, like Finder's: a change in one shows in all.
    var showHidden = UserDefaults.standard.bool(forKey: SettingsKey.showHidden) {
        didSet {
            guard showHidden != oldValue else { return }
            UserDefaults.standard.set(showHidden, forKey: SettingsKey.showHidden)
            refreshVisible()
            NotificationCenter.default.post(name: .showHiddenChanged, object: self)
        }
    }

    /// Only names containing this are shown (⌘F); the folder's listing isn't read again.
    /// Cleared when the window moves to another folder.
    var nameFilter = "" {
        didSet { if nameFilter != oldValue { applyNameFilter() } }
    }

    /// The filter is a regular expression (ignoring case) that names match, rather than text
    /// they contain. Remembered for the next window.
    var nameFilterIsRegex = UserDefaults.standard.bool(forKey: SettingsKey.searchUsesRegex) {
        didSet {
            guard nameFilterIsRegex != oldValue else { return }
            UserDefaults.standard.set(nameFilterIsRegex, forKey: SettingsKey.searchUsesRegex)
            applyNameFilter()
        }
    }

    /// The filter is a regular expression that isn't valid; nothing is shown.
    private(set) var nameFilterIsInvalid = false

    /// Rows before the name filter: hidden ones left out, sorted. Kept so typing in the filter
    /// doesn't sort again.
    private var sortedEntries: [RemoteEntry] = []
    private var sortedIndex: [String: Int] = [:]
    /// How many rows there are without the name filter.
    var unfilteredCount: Int { sortedEntries.count }

    private var entries: [RemoteEntry] = []
    private var changeObserver: NSObjectProtocol?
    private var hiddenObserver: NSObjectProtocol?

    init() {
        // Reload when a transfer changed the folder this window shows.
        changeObserver = NotificationCenter.default.addObserver(forName: .remoteFolderChanged, object: nil, queue: .main) { [weak self] note in
            let deviceID = note.userInfo?["deviceID"] as? String
            let path = note.userInfo?["path"] as? String
            MainActor.assumeIsolated {
                guard let self, deviceID == self.deviceID, path == self.location?.path else { return }
                self.reload()
            }
        }
        hiddenObserver = NotificationCenter.default.addObserver(forName: .showHiddenChanged, object: nil, queue: .main) { [weak self] note in
            let sender = (note.object as AnyObject?).map(ObjectIdentifier.init)
            MainActor.assumeIsolated {
                guard let self, sender != ObjectIdentifier(self) else { return }
                self.showHidden = UserDefaults.standard.bool(forKey: SettingsKey.showHidden)
            }
        }
    }

    /// Back/forward span devices: one history line per window.
    private var backStack: [HistoryEntry] = []
    private var forwardStack: [HistoryEntry] = []

    /// The device this browser shows; set by the window.
    var deviceID: String?
    /// History stepped onto another device; the window switches to it.
    var onSwitchDevice: ((String, String) -> Void)?

    private var currentEntry: HistoryEntry? {
        guard let deviceID, let location else { return nil }
        return HistoryEntry(deviceID: deviceID, path: location.path)
    }
    private var listTask: Task<Void, Never>?

    var canGoBack: Bool { !backStack.isEmpty }
    var canGoForward: Bool { !forwardStack.isEmpty }
    var canGoUp: Bool { location?.parentPath != nil }

    /// Every name in the folder, hidden ones included.
    var allNames: Set<String> { Set(entries.map(\.name)) }

    var selectedEntries: [RemoteEntry] {
        visibleEntries.filter { selection.contains($0.id) }
    }

    func attach(_ fs: any DeviceFileSystem, startAt start: RemoteRef? = nil) {
        guard fs !== fileSystem else { return }
        fileSystem = fs
        if let location {
            load(location)
        } else if let target = start ?? fs.roots.first?.ref {
            navigate(to: target)
        }
    }

    func detach(resetLocation: Bool) {
        listTask?.cancel()
        fileSystem = nil
        isLoading = false
        selection = []
        if resetLocation {
            location = nil
            entries = []
            visibleEntries = []
        }
    }

    /// Sets where the window starts before any device is attached (restored windows).
    func setPendingLocation(_ path: String) {
        guard fileSystem == nil else { return }
        location = RemoteRef(path: path)
    }

    func navigate(to ref: RemoteRef) {
        if let current = currentEntry, current.path != ref.path {
            backStack.append(current)
            forwardStack.removeAll()
        }
        load(ref)
    }

    /// Called before the window switches to another device, so Back returns here.
    func recordDeviceSwitch() {
        guard let current = currentEntry else { return }
        backStack.append(current)
        forwardStack.removeAll()
    }

    func activate(_ entry: RemoteEntry) {
        // Symlinks (e.g. /sdcard) are usually directories; try listing them.
        if entry.kind == .directory || entry.kind == .symlink { navigate(to: entry.ref) }
    }

    func goBack() {
        guard let previous = backStack.popLast() else { return }
        if let current = currentEntry { forwardStack.append(current) }
        go(to: previous)
    }

    func goForward() {
        guard let next = forwardStack.popLast() else { return }
        if let current = currentEntry { backStack.append(current) }
        go(to: next)
    }

    private func go(to entry: HistoryEntry) {
        if entry.deviceID == deviceID {
            load(RemoteRef(path: entry.path))
        } else {
            onSwitchDevice?(entry.deviceID, entry.path)
        }
    }

    func goUp() {
        guard let parent = location?.parentPath, let location else { return }
        let child = location.path
        navigate(to: RemoteRef(path: parent))
        pendingSelection = child
    }

    func reload(selecting path: String? = nil, rename: Bool = false) {
        pendingSelection = path
        pendingRename = rename
        if let location { load(location) }
    }

    // MARK: File operations

    /// Creates "New Folder" (or "New Folder 2", …) here and starts renaming it, like Finder.
    func createFolder() async {
        guard let fs = fileSystem, let location else { return }
        let base = String(localized: "New Folder")
        let taken = FolderNames(entries.map(\.name))
        var name = base
        var n = 2
        while taken.contains(name) {
            name = "\(base) \(n)"
            n += 1
        }
        let ref = location.appending(name)
        let device = deviceID
        do {
            try await fs.makeDirectory(ref)
            // The window may have gone to another device meanwhile; that one's folder stays as it is.
            guard deviceID == device else { return }
            nameFilter = "" // the new folder shows, whatever its name
            reload(selecting: ref.path, rename: true)
        } catch {
            operationError = UserMessage.describe(error)
        }
    }

    func rename(_ entry: RemoteEntry, to newName: String) async {
        guard newName != entry.name, let fs = fileSystem else { return }
        let device = deviceID
        do {
            let renamed = try await fs.rename(entry.ref, to: newName)
            onRenamed?(device, entry.ref.path, renamed.path)
            if deviceID == device { reload(selecting: renamed.path) }
        } catch {
            operationError = UserMessage.describe(error)
        }
    }

    /// Runs the steps of a batch rename in this folder, one at a time. Returns what went
    /// wrong, if anything; the folder is reloaded either way.
    func batchRename(_ steps: [(from: String, to: String)], progress: (Int) -> Void) async -> String? {
        guard let fs = fileSystem, let folder = location else { return nil }
        let device = deviceID
        var failure: String?
        for (index, step) in steps.enumerated() {
            do {
                let renamed = try await fs.rename(folder.appending(step.from), to: step.to)
                onRenamed?(device, folder.appending(step.from).path, renamed.path)
                progress(index + 1)
            } catch {
                failure = String(localized: "Stopped after \(index) of \(steps.count) renames: \(UserMessage.describe(error))")
                break
            }
        }
        guard deviceID == device else { return failure }
        let finalNames = Set(steps.map(\.to).filter { !WorkNames.isWorkFile($0) })
        selection = Set(finalNames.map { folder.appending($0).path })
        reload()
        return failure
    }

    func delete(_ targets: [RemoteEntry]) async {
        guard let fs = fileSystem, !targets.isEmpty else { return }
        let device = deviceID
        do {
            try await fs.delete(targets.map(\.ref))
            onDeleted?(device, targets.map(\.ref.path))
        } catch {
            operationError = UserMessage.describe(error)
        }
        if deviceID == device { reload() }
    }

    /// After going up, select the folder we came from once it's listed.
    private var pendingSelection: String?

    private func load(_ ref: RemoteRef) {
        listTask?.cancel()
        // Results tagged with an older generation belong to a folder we already left.
        generation += 1
        let myGeneration = generation
        let changedFolder = ref != location
        location = ref
        error = nil
        connectionLost = false
        if changedFolder {
            entries = []
            sortedEntries = []
            sortedIndex = [:]
            visibleEntries = []
            selection = []
            nameFilter = ""
        }
        detailsPending = false
        guard let fs = fileSystem else {
            isLoading = false
            return
        }
        isLoading = true
        loadedCount = 0
        loadStarted = Date()
        listingLog.debug("load requested")
        listTask = Task {
            let start = ContinuousClock.now
            listingLog.debug("load task started")
            var received: [RemoteEntry] = []
            var index: [String: Int] = [:]
            var partialCount = 0
            // Reloading the same folder: reuse the sizes/dates we already had for rows the new
            // listing hasn't detailed yet, so nothing blanks out while they refresh.
            let previous = changedFolder ? [:] : Dictionary(entries.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
            @MainActor func isCurrent() -> Bool { !Task.isCancelled && myGeneration == self.generation }
            var firstShown = false
            var mainThreadTime = Duration.zero
            func ms(_ d: Duration) -> String { d.formatted(.units(allowed: [.milliseconds])) }
            do {
                for try await batch in fs.list(ref) {
                    guard isCurrent() else { return }
                    let batchStart = ContinuousClock.now
                    if !firstShown { listingLog.debug("first batch received after \(ms(batchStart - start), privacy: .public)") }
                    defer { mainThreadTime += ContinuousClock.now - batchStart }
                    var added = false
                    var updated: [RemoteEntry] = []
                    for var entry in batch {
                        if entry.isPartial, let old = previous[entry.id], !old.isPartial {
                            entry = RemoteEntry(ref: entry.ref, name: entry.name, kind: entry.kind,
                                                size: old.size, modified: old.modified, isPartial: true)
                        }
                        if let i = index[entry.id] {
                            if received[i].isPartial { partialCount -= 1 }
                            received[i] = entry
                            updated.append(entry)
                        } else {
                            index[entry.id] = received.count
                            received.append(entry)
                            added = true
                        }
                        if entry.isPartial { partialCount += 1 }
                    }
                    loadedCount = received.count
                    detailsPending = partialCount > 0
                    // Names are on screen as soon as they arrive — never held back for details.
                    do {
                        entries = received
                        if !added && detailsPending {
                            // Details trickling in (possibly 100s of small batches): patch those
                            // rows in place; order can't change while size/date sorts wait.
                            updateVisibleInPlace(updated)
                        } else {
                            refreshVisible()
                        }
                        applyPendingSelection()
                        if !firstShown {
                            firstShown = true
                            listingLog.debug("first rows on screen: \(received.count) after \(ms(ContinuousClock.now - start), privacy: .public) (this batch took \(ms(ContinuousClock.now - batchStart), privacy: .public) on main)")
                        }
                    }
                }
            } catch {
                guard isCurrent() else { return }
                listingLog.error("load failed: \(String(describing: error), privacy: .public)")
                if fs.isConnectionLoss(error) {
                    connectionLost = true
                    onConnectionLost?(fs)
                    detailsPending = false
                    isLoading = false
                    return
                }
                self.error = UserMessage.describe(error)
                onLoadFailure?(ref.path)
                entries = []
                detailsPending = false
                isLoading = false
                refreshVisible()
                return
            }
            guard isCurrent() else { return }
            entries = received
            detailsPending = false
            isLoading = false // before refreshVisible: the selection keeps only rows that are here
            refreshVisible()
            applyPendingSelection()
            if pendingRename, let id = pendingSelection, visibleEntries.contains(where: { $0.id == id }) {
                renamingID = id
            }
            pendingSelection = nil
            pendingRename = false
            listingLog.notice("listing complete: \(received.count) in \(ms(ContinuousClock.now - start), privacy: .public), main thread \(ms(mainThreadTime), privacy: .public)")
        }
    }

    private func applyPendingSelection() {
        if let pending = pendingSelection, selection != [pending], visibleEntries.contains(where: { $0.id == pending }) {
            selection = [pending]
        }
    }

    /// Index of each visible row by id, for in-place updates.
    private var visibleIndex: [String: Int] = [:]

    private func updateVisibleInPlace(_ changed: [RemoteEntry]) {
        for entry in changed {
            if let i = sortedIndex[entry.id] { sortedEntries[i] = entry }
            if let i = visibleIndex[entry.id] { visibleEntries[i] = entry }
        }
    }

    /// Rows now on screen: let the backend fetch their missing details first.
    func visibleRowsChanged(_ ids: [String]) {
        guard detailsPending, let fileSystem else { return }
        let refs = ids.compactMap { id in visibleIndex[id].map { visibleEntries[$0] } }.filter(\.isPartial).map(\.ref)
        if !refs.isEmpty { fileSystem.prioritizeDetails(refs) }
    }

    private func refreshVisible() {
        let filtered = showHidden ? entries : entries.filter { !$0.isHidden }
        // Sorting by size/date before those arrive would reshuffle rows as they fill in; keep
        // name order until they're all here.
        let effective = sortIsDeferred ? BrowserSort() : sort
        sortedEntries = filtered.sorted(by: Self.comparator(effective))
        sortedIndex = Dictionary(uniqueKeysWithValues: sortedEntries.enumerated().map { ($1.id, $0) })
        applyNameFilter()
    }

    /// The sorted rows whose names contain the filter, ignoring case, accents and width as
    /// Finder does (or match it, as a regular expression); the selection keeps only rows still
    /// shown. While a listing streams in, a selected row that hasn't arrived again yet stays
    /// selected.
    private func applyNameFilter() {
        let needle = nameFilter.trimmingCharacters(in: .whitespaces)
        nameFilterIsInvalid = false
        if needle.isEmpty {
            visibleEntries = sortedEntries
        } else if nameFilterIsRegex {
            if let regex = try? NSRegularExpression(pattern: needle, options: .caseInsensitive) {
                visibleEntries = sortedEntries.filter { entry in
                    regex.firstMatch(in: entry.name, range: NSRange(entry.name.startIndex..., in: entry.name)) != nil
                }
            } else {
                visibleEntries = []
                nameFilterIsInvalid = true
            }
        } else {
            visibleEntries = sortedEntries.filter { $0.name.localizedStandardContains(needle) }
        }
        visibleIndex = Dictionary(uniqueKeysWithValues: visibleEntries.enumerated().map { ($1.id, $0) })
        let ids = Set(visibleEntries.map(\.id))
        guard !selection.isSubset(of: ids) else { return }
        if isLoading {
            let arrived = Set(entries.map(\.id))
            selection.subtract(selection.filter { arrived.contains($0) && !ids.contains($0) })
        } else {
            selection.formIntersection(ids)
        }
    }

    /// Folders first, then by key; ties broken by name.
    private static func comparator(_ sort: BrowserSort) -> (RemoteEntry, RemoteEntry) -> Bool {
        { a, b in
            if a.isDirectory != b.isDirectory { return a.isDirectory }
            let order: ComparisonResult = switch sort.key {
            case .name: a.name.localizedStandardCompare(b.name)
            case .size: compare(a.size ?? 0, b.size ?? 0)
            case .modified: compare(a.modified ?? .distantPast, b.modified ?? .distantPast)
            case .kind: a.fileExtension.compare(b.fileExtension)
            }
            if order == .orderedSame {
                return a.name.localizedStandardCompare(b.name) == .orderedAscending
            }
            return sort.ascending ? order == .orderedAscending : order == .orderedDescending
        }
    }

    private static func compare<T: Comparable>(_ a: T, _ b: T) -> ComparisonResult {
        a < b ? .orderedAscending : a > b ? .orderedDescending : .orderedSame
    }
}

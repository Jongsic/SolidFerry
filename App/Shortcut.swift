import DeviceCore
import Foundation

struct Shortcut: Hashable {
    let name: String
    let path: String
    let icon: String

    /// Candidates; only the ones that exist on the device are shown.
    static let candidates = [
        Shortcut(name: String(localized: "Internal Storage"), path: "/sdcard", icon: "internaldrive"),
        Shortcut(name: String(localized: "Camera"), path: "/sdcard/DCIM/Camera", icon: "camera"),
        Shortcut(name: String(localized: "Screenshots"), path: "/sdcard/DCIM/Screenshots", icon: "camera.viewfinder"),
        Shortcut(name: String(localized: "Screenshots"), path: "/sdcard/Pictures/Screenshots", icon: "camera.viewfinder"),
        Shortcut(name: String(localized: "Downloads"), path: "/sdcard/Download", icon: "arrow.down.circle"),
        Shortcut(name: String(localized: "Pictures"), path: "/sdcard/Pictures", icon: "photo"),
        Shortcut(name: String(localized: "Movies"), path: "/sdcard/Movies", icon: "film"),
        Shortcut(name: String(localized: "Documents"), path: "/sdcard/Documents", icon: "doc"),
        Shortcut(name: String(localized: "Recordings"), path: "/sdcard/Recordings", icon: "waveform"),
    ]

    static func existing(in fs: any DeviceFileSystem) async -> [Shortcut] {
        let found = await withTaskGroup(of: String?.self) { group in
            for shortcut in candidates {
                group.addTask {
                    let entry = try? await fs.entry(at: RemoteRef(path: shortcut.path))
                    return entry?.isDirectory == true ? shortcut.path : nil
                }
            }
            var paths = Set<String>()
            for await path in group { if let path { paths.insert(path) } }
            return paths
        }
        return candidates.filter { found.contains($0.path) } + removable(fs.roots)
    }

    /// Storages besides the internal one: SD cards and USB drives (named the way the phone's
    /// own Files app does), or an MTP storage by the name the device gives it.
    static func removable(_ roots: [RemoteLocation]) -> [Shortcut] {
        let others = roots.filter { $0.kind != .internalStorage }
        return others.map { root in
            let (name, icon): (String, String) = switch root.kind {
            case .sdCard: (String(localized: "SD Card"), "sdcard")
            case .usbDrive: (String(localized: "USB Drive"), "externaldrive")
            case .internalStorage, .other: (root.name, "externaldrive")
            }
            // Two of a kind: tell them apart by the volume's ID.
            let shared = others.filter { $0.kind == root.kind && $0.kind != .other }.count > 1
            return Shortcut(name: shared ? "\(name) (\(root.ref.name))" : name, path: root.ref.path, icon: icon)
        }
    }
}

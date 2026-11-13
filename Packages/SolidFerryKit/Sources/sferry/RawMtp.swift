import Foundation
import MtpKit

/// An MTP session opened directly, for the experiments that talk to the phone below
/// `MtpFileSystem`: the first storage, and paths walked one folder at a time.
struct RawMtp {
    let session: MtpSession
    let storage: UInt32

    static func open(serial: String) throws -> RawMtp {
        let session = try MtpSession(serial: serial)
        try session.openSession()
        guard let storage = try session.storageIDs().first else {
            session.closeSession()
            fail("no storage (phone locked?)")
        }
        return RawMtp(session: session, storage: storage)
    }

    func close() {
        session.closeSession()
    }

    /// The item at `path` ("/DCIM/Camera", or with "/sdcard" in front); nil for the storage
    /// itself. `allProperties` lists each folder with one request for every property (the
    /// way `mtp-ls` measures it) instead of one per property.
    func find(_ path: String, allProperties: Bool = false) throws -> MtpObjectInfo? {
        var parent: UInt32 = 0xFFFF_FFFF
        var found: MtpObjectInfo?
        let components = path.split(separator: "/")
        for component in components.dropFirst(components.first == "sdcard" ? 1 : 0) {
            let children = parent == 0xFFFF_FFFF
                ? try session.objectHandles(storage: storage, parent: parent).map { try session.objectInfo($0) }
                : allProperties ? try session.objectPropList(children: parent) : try session.objectPropListByProperty(children: parent)
            guard let match = children.first(where: { $0.name == component }) else { fail("not found: \(component)") }
            parent = match.handle
            found = match
        }
        return found
    }

    /// The handle to list or create in for a folder path (the storage root for "/").
    func folder(_ path: String, allProperties: Bool = false) throws -> UInt32 {
        try find(path, allProperties: allProperties)?.handle ?? 0xFFFF_FFFF
    }
}

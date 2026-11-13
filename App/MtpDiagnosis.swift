import Foundation
import MtpKit
import UsbKit

/// The MTP side of a phone as the connection panel and checklist explain it, decided here in
/// one place so the views don't look at MtpKit or UsbKit types (AGENTS.md, Layers).
struct MtpDiagnosis: Equatable {
    /// Why the last attempt failed.
    enum Problem: Equatable {
        case chargingOnly
        /// Locked, or "File transfer" not chosen: no storage offered.
        case noStorage
        case unresponsive
        case unknown
    }

    /// An app holding the phone's file access.
    struct Holder: Equatable, Identifiable {
        /// nil when only its name is known (the failed attempt named it).
        let pid: pid_t?
        let name: String
        var id: String { pid.map(String.init) ?? name }
    }

    var cabled = false
    var hasInterface = false
    var connecting = false
    /// The phone is finishing an earlier request before it answers.
    var phoneBusy = false
    var ready = false
    var problem: Problem?
    /// Apps other than this one holding the phone (macOS's photo service apart).
    var blockers: [Holder] = []
    /// macOS's photo service holds the phone; it's taken over automatically.
    var photoServiceHolds = false
    /// Display names of everything holding the phone, photo service included.
    var holderNames: [String] = []
}

extension DeviceSession {
    var mtpDiagnosis: MtpDiagnosis {
        var d = MtpDiagnosis()
        d.cabled = usb != nil
        d.hasInterface = usb?.hasMTP == true
        if case .connected(_, .mtp) = phase { d.ready = true }
        if case .connecting(.mtp, _, _) = phase { d.connecting = true }
        d.phoneBusy = connectStage == .phoneBusy
        let owners = (usb?.mtpOwners ?? []).filter { $0.pid != ProcessInfo.processInfo.processIdentifier }
        d.holderNames = owners.map(\.name)
        d.photoServiceHolds = owners.contains(where: \.isPhotoService) && fileSystem == nil
        d.blockers = owners.filter { !$0.isPhotoService }.map { MtpDiagnosis.Holder(pid: $0.pid, name: $0.name) }
        if let failure = mtpFailure {
            switch failure {
            case .chargingOnly: d.problem = .chargingOnly
            case .noStorage: d.problem = .noStorage
            case .unresponsive: d.problem = .unresponsive
            case .busy(let names):
                // The attempt saw them; the registry may not list them any more.
                if d.blockers.isEmpty { d.blockers = names.map { MtpDiagnosis.Holder(pid: nil, name: $0) } }
            case .notFound, .other: d.problem = .unknown
            }
        }
        if fileSystem != nil { d.blockers = [] }
        return d
    }
}

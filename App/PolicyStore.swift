import Foundation
import TransferKit

/// The copy options last used, offered again next time. There's no separate "default".
enum PolicyStore {
    private static let key = SettingsKey.lastTransferPolicy

    static var lastPolicy: TransferPolicy {
        get {
            guard let data = UserDefaults.standard.data(forKey: key),
                  let policy = try? JSONDecoder().decode(TransferPolicy.self, from: data) else { return TransferPolicy() }
            return policy
        }
        set {
            UserDefaults.standard.set(try? JSONEncoder().encode(newValue), forKey: key)
        }
    }

    /// Remembers the options of a transfer that's starting. "Only set the date" is offered for
    /// downloads alone; another kind of transfer keeps what it was.
    static func remember(_ policy: TransferPolicy, toMac: Bool) {
        var policy = policy
        if !toMac { policy.datesOnlyWhenSameSize = lastPolicy.datesOnlyWhenSameSize }
        lastPolicy = policy
    }

    private static let destinationKey = SettingsKey.lastDownloadFolder

    static var lastDestination: URL {
        get {
            UserDefaults.standard.url(forKey: destinationKey)
                ?? FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask).first!
        }
        set { UserDefaults.standard.set(newValue, forKey: destinationKey) }
    }
}

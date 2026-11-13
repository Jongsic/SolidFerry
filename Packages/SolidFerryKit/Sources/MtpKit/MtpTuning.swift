import Foundation

/// How many times to try, and how long to wait in between.
struct Retry: Sendable {
    let attempts: Int
    let interval: Duration
}

/// Waits, timeouts and sizes set by how phones behave, each with the QUIRKS entry it answers.
public enum MtpTuning {
    // MARK: Connecting

    /// Another client holding the interface (a just-closed session, macOS's image capture
    /// daemon probing a new phone) usually lets go within two seconds. QUIRKS H1.
    static let interfaceBusy = Retry(attempts: 8, interval: .milliseconds(250))
    /// The interface can't be created for a moment after another client let go of the phone
    /// or was killed mid-transfer. QUIRKS M12.
    static let interfaceUnavailable = Retry(attempts: 12, interval: .milliseconds(500))
    /// The phone ignores OpenSession while it finishes an earlier client's request; much longer
    /// after taking it over from macOS's photo service, which leaves it listing every photo. QUIRKS M7.
    static func sessionPatience(tookOverPhotoService: Bool) -> TimeInterval { tookOverPhotoService ? 90 : 15 }
    /// Storage is empty for a moment after plugging in or switching to File transfer. QUIRKS M16.
    static let storageWait = Retry(attempts: 12, interval: .milliseconds(500))

    // MARK: Writing

    /// Putting a file under a name whose old file was just deleted: a Galaxy can report the
    /// delete done and keep the file; it's deleted again and the name retried. QUIRKS G10.
    static let freedNameWait = Retry(attempts: 5, interval: .milliseconds(100))

    // MARK: Timeouts (QUIRKS M6: some phones answer slowly)

    /// Most commands.
    public static let commandTimeout: TimeInterval = 30
    /// Sending a command or a small data phase. Short, so a phone that isn't reading shows up
    /// quickly (and gets drained and retried).
    static let writeTimeout: TimeInterval = 4
    /// One chunk of a file, either way, and the response that ends an upload.
    static let transferTimeout: TimeInterval = 60
    /// A folder's properties in one request (QUIRKS M2: sizes and dates can take 20 s).
    static let listingTimeout: TimeInterval = 120
    /// One bulk transfer of an upload chunk.
    static let sendChunkTimeout: TimeInterval = 30
    /// CopyObject: the phone copies the whole file before it answers.
    static let copyTimeout: TimeInterval = 600

    // MARK: Sizes

    /// One GetPartialObject64 request, to start with and at least. Pause, cancel and browsing
    /// land between chunks, since cancelling a transaction midway can stop the phone's MTP
    /// server (QUIRKS M8). From there a download's chunks are sized to take about
    /// `readChunkSeconds`, up to `readChunkMax`: each request costs about 6 ms on top of its
    /// data (Galaxy S23 over USB 3: 8 MB 190 MB/s, 32 MB 210, 64 MB 218), so on a fast link
    /// bigger chunks are faster, while on USB 2 (about 40 MB/s) 8 MB already takes 0.2 s.
    public static let readChunk: UInt64 = 8 << 20
    /// One request of a range read (media played while it's read): 1 MB is about 5 ms over
    /// USB 3, 25 ms over USB 2, so a jump in the video shows quickly.
    static let rangeChunk: UInt64 = 1 << 20
    static let readChunkMax: UInt64 = 64 << 20
    static let readChunkSeconds = 0.2
    /// Big chunks only when nothing was browsed this recently: a listing takes 3–4 requests,
    /// each waiting for the chunk in flight, so with 0.2 s chunks it took about 0.6 s instead
    /// of 0.17 s while downloading (S23, USB 3).
    static let browsingQuiet: Duration = .seconds(1)
    /// While browsing, chunks of about this long (1–8 MB): on USB 2 an 8 MB chunk takes 0.2 s,
    /// which made a listing during a download take about 0.66 s.
    static let browsingChunkSeconds = 0.05
    static let browsingChunkRange: ClosedRange<UInt64> = (1 << 20)...(8 << 20)
    /// One bulk transfer of an upload: a whole number of USB packets, since a shorter one
    /// ends the data phase on the phone (QUIRKS M9).
    static let sendChunk = 1 << 20
    /// Big folders get sizes and dates in chunks sized to take about this long, so browsing
    /// never waits longer behind them (QUIRKS M2). Chunks start at 20 objects and stay within
    /// 5...200 (2–7 ms per object measured).
    static let detailsChunkSeconds = 0.15
    static let detailsChunkStart = 20
    static let detailsChunkRange = 5...200
    /// Folders up to this size get sizes and dates in two bulk requests (QUIRKS M2, M4).
    static let bulkDetailsLimit = 500
    /// Files selected before their details came (`completingDetails`): asked in bulk for the
    /// whole folder when this many are missing, or this share of the folder; one by one otherwise.
    static let bulkWhenMissing = 500
    static let bulkWhenMissingShare = 0.25
}

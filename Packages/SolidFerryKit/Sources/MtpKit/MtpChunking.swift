import Foundation

/// How many objects to ask about per details request in a big folder: sized from how fast the
/// phone answered the last request, to take about `MtpTuning.detailsChunkSeconds` (QUIRKS M2).
struct DetailsChunker {
    private(set) var size = MtpTuning.detailsChunkStart

    mutating func answered(_ count: Int, in seconds: Double) {
        guard count > 0 else { return }
        let perObject = max(seconds / Double(count), 0.0005)
        let range = MtpTuning.detailsChunkRange
        size = min(range.upperBound, max(range.lowerBound, Int(MtpTuning.detailsChunkSeconds / perObject)))
    }
}

/// How much of a file one read request asks for, sized from how fast the last full request
/// came in: about `MtpTuning.readChunkSeconds` of data when nobody's browsing, so fast links
/// aren't held back by per-request costs, and about `MtpTuning.browsingChunkSeconds` while
/// browsing, since each of a listing's requests waits for the chunk in flight
/// (`MtpWorker.browsedRecently`). Until a speed is known, `MtpTuning.readChunk`.
struct ReadChunker {
    /// Bytes per second, from the last full request.
    private(set) var rate: Double?

    func size(browsing: Bool) -> UInt64 {
        guard let rate else { return MtpTuning.readChunk }
        let (seconds, range) = browsing
            ? (MtpTuning.browsingChunkSeconds, MtpTuning.browsingChunkRange)
            : (MtpTuning.readChunkSeconds, MtpTuning.readChunk...MtpTuning.readChunkMax)
        let megabytes = UInt64(rate * seconds) >> 20
        return min(range.upperBound, max(range.lowerBound, megabytes << 20))
    }

    /// A request asked for `requested` bytes and got `bytes` in `seconds` (time on the phone,
    /// not in the queue). A short last piece of a file says little about the link.
    mutating func read(_ bytes: UInt64, of requested: UInt64, in seconds: Double) {
        guard bytes >= requested / 2, seconds > 0 else { return }
        rate = Double(bytes) / seconds
    }
}

/// USB packet arithmetic for MTP data phases.
enum MtpPackets {
    /// Whether a data container with `bodyLength` bytes (plus its 12-byte header) ends exactly
    /// on a packet boundary, for this endpoint's packet size or USB 2's 512.
    static func endsOnFullPacket(bodyLength: UInt64, maxPacket: Int) -> Bool {
        let container = bodyLength + 12
        return container % UInt64(maxPacket) == 0 || container % 512 == 0
    }

    /// How much to ask for at `offset`: up to `maxLength`, but a file's last piece is one byte
    /// short when it would end on a full packet (Samsung hangs on that reply, QUIRKS M10); the
    /// next request gets that byte.
    static func readLength(size: UInt64, offset: UInt64, maxLength: UInt64, maxPacket: Int) -> UInt64 {
        let length = min(maxLength, size - offset)
        if offset + length == size, length > 1, endsOnFullPacket(bodyLength: length, maxPacket: maxPacket) { return length - 1 }
        return length
    }
}

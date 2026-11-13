@testable import AdbKit
import DeviceCore
import Foundation
import Testing

@Test func parsesDeviceList() {
    let text = """
    R5XX00FGHIJ            device usb:1-1 product:dm3qksx model:SM_S918N device:dm3q transport_id:3
    192.168.0.5:41234      unauthorized transport_id:4
    """
    let devices = AdbDeviceInfo.parseList(text)
    #expect(devices.count == 2)
    #expect(devices[0].serial == "R5XX00FGHIJ")
    #expect(devices[0].state == .device)
    #expect(devices[0].model == "SM_S918N")
    #expect(devices[0].isWireless == false)
    #expect(devices[1].state == .unauthorized)
    #expect(devices[1].isWireless)
}

@Test func fourCCMatchesAdbMKID() {
    // MKID('D','A','T','A') = 'D' | 'A'<<8 | 'T'<<16 | 'A'<<24
    #expect(SyncID.data == 0x4154_4144)
}

@Test func parsesDentV2() {
    var bytes = [UInt8](repeating: 0, count: SyncWire.dentV2Size)
    func put32(_ value: UInt32, at offset: Int) {
        withUnsafeBytes(of: value.littleEndian) { for (i, b) in $0.enumerated() { bytes[offset + i] = b } }
    }
    func put64(_ value: UInt64, at offset: Int) {
        withUnsafeBytes(of: value.littleEndian) { for (i, b) in $0.enumerated() { bytes[offset + i] = b } }
    }
    put32(SyncID.dentV2, at: 0)
    put32(0o100644, at: 24)
    put64(5_000_000_000, at: 40) // > 4GB, only representable in v2
    put64(1_700_000_000, at: 56)
    put32(9, at: 72)

    let (stat, nameLength) = bytes.withUnsafeBytes { SyncWire.parseDentV2($0.baseAddress!) }
    #expect(stat.isRegularFile)
    #expect(stat.size == 5_000_000_000)
    #expect(stat.mtime == 1_700_000_000)
    #expect(stat.error == 0)
    #expect(nameLength == 9)
}

@Test func parsesDentV1() {
    // id, mode, size (32-bit), mtime, name length.
    let bytes: [UInt8] = [0x44, 0x45, 0x4E, 0x54, 0xED, 0x41, 0x00, 0x00, 0x00, 0x10, 0x00, 0x00,
                          0x00, 0xF1, 0x53, 0x65, 0x04, 0x00, 0x00, 0x00]
    let (stat, nameLength) = bytes.withUnsafeBytes { SyncWire.parseDentV1($0.baseAddress!) }
    #expect(stat.isDirectory && stat.mode == 0o40755)
    #expect(stat.size == 4096 && stat.mtime == 1_700_000_000 && stat.error == 0)
    #expect(nameLength == 4)
}

@Test func entriesFromStats() {
    let ref = RemoteRef(path: "/sdcard/x")
    func entry(mode: UInt32, error: UInt32 = 0) -> RemoteEntry {
        AdbFileSystem.makeEntry(SyncStat(mode: mode, size: 5_000_000_000, mtime: 1_700_000_000, error: error), name: "x", ref: ref)
    }
    let file = entry(mode: 0o100644)
    #expect(file.kind == .file && file.size == 5_000_000_000)
    #expect(file.modified == Date(timeIntervalSince1970: 1_700_000_000))
    // Folders and links carry no size.
    #expect(entry(mode: 0o040755).kind == .directory && entry(mode: 0o040755).size == nil)
    #expect(entry(mode: 0o120777).kind == .symlink && entry(mode: 0o120777).size == nil)
    #expect(entry(mode: 0o020666).kind == .other)
    // An entry the phone couldn't stat (v2 error field) is listed with nothing known.
    let failed = entry(mode: 0o100644, error: 13)
    #expect(failed.kind == .other && failed.size == nil && failed.modified == nil)
}

@Test func shellQuoteEscapesSingleQuotes() {
    #expect(AdbFileSystem.shellQuote("/sdcard/it's a file.jpg") == #"'/sdcard/it'\''s a file.jpg'"#)
}

@Test func mdnsServicesParse() {
    let text = "adb-R5XX00ABCDE-AbCdEf\t_adb-tls-connect._tcp\t192.168.0.12:41234\n"
        + "studio-x1y2\t_adb-tls-pairing._tcp\t192.168.0.12:37000\n"
    let services = AdbMdnsService.parse(text)
    #expect(services.count == 2)
    #expect(services[0].kind == .connect)
    #expect(services[0].deviceSerial == "R5XX00ABCDE")
    #expect(services[0].address == "192.168.0.12:41234")
    #expect(services[1].kind == .pairing)
    #expect(services[1].deviceSerial == nil)
    #expect(wirelessSerial(fromInstance: "adb-HVA0AAAA-q1W2e3._adb-tls-connect._tcp") == "HVA0AAAA")
    #expect(wirelessSerial(fromInstance: "192.168.0.12:5555") == nil)
    #expect(pairedSerial(fromReply: "Successfully paired to 192.168.0.41:38293 [guid=adb-R5XX00ABCDE-vevFBn]") == "R5XX00ABCDE")
    #expect(pairedSerial(fromReply: "Successfully paired to 192.168.0.41:38293") == nil)
}

@Test func tarHeaderNumbers() throws {
    var header = [UInt8](repeating: 0, count: 512)
    let octal = Array("00000010000\0".utf8)
    header.replaceSubrange(124..<136, with: octal)
    #expect(try header.withUnsafeBytes { try TarReader.number($0, 124, 12) } == 4096)
    header[124] = 0x80
    for i in 125..<136 { header[i] = 0 }
    header[134] = 0x01
    header[135] = 0x00
    #expect(try header.withUnsafeBytes { try TarReader.number($0, 124, 12) } == 256)
    #expect(TarReader.paxPath("30 path=sdcard/DCIM/a long.jpg\n20 mtime=1700000000\n") == "sdcard/DCIM/a long.jpg")
    #expect(AdbFileSystem.tarName("/sdcard/DCIM/a.jpg") == "sdcard/DCIM/a.jpg")
}

@Test func wirelessEndpointFromPhone() {
    let text = """
    1
        inet 172.18.100.59/16 brd 172.18.255.255 scope global wlan0
      sl  local_address                         remote_address                        st tx_queue rx_queue tr tm->when retrnsmt   uid  timeout inode
       0: 0000000000000000FFFF00000100007F:A135 00000000000000000000000000000000:0000 0A 00000000:00000000 00:00000000 00000000 10148        0 3846160 1
       1: 00000000000000000000000000000000:A817 00000000000000000000000000000000:0000 0A 00000000:00000000 00:00000000 00000000  2000        0 3936820 1
    """
    let endpoint = WirelessEndpoint.parse(text)
    #expect(endpoint.enabled)
    #expect(endpoint.address == "172.18.100.59:43031")
    #expect(WirelessEndpoint.parse("0\n").enabled == false)
}

@Test func shellExitStatusParse() {
    let ok = AdbFileSystem.parseExitStatus("hello\n__XFER_RC=0\n")
    #expect(ok?.code == 0 && ok?.printed == "hello")
    let failed = AdbFileSystem.parseExitStatus("mv: bad 'x': No such file\n__XFER_RC=1\n")
    #expect(failed?.code == 1 && failed?.printed == "mv: bad 'x': No such file")
    #expect(AdbFileSystem.parseExitStatus("no marker") == nil)
}

@Test func md5sumParse() {
    let text = """
    d41d8cd98f00b204e9800998ecf8427e  /sdcard/a b.txt
    md5sum: /sdcard/missing: No such file or directory
    0cc175b9c0f1b6a831c399e269772661  /sdcard/한글.txt
    """
    let hashes = AdbFileSystem.parseMD5Sum(text)
    #expect(hashes == ["/sdcard/a b.txt": "d41d8cd98f00b204e9800998ecf8427e",
                       "/sdcard/한글.txt": "0cc175b9c0f1b6a831c399e269772661"])
}

@Test func shellArgumentsAreBatchedByBytes() {
    // 3-byte letters: counting characters would put all of these in one 64 KB request.
    let korean = Array(repeating: AdbFileSystem.shellQuote(String(repeating: "가", count: 100)), count: 300)
    let batches = AdbFileSystem.argumentBatches(korean, limit: 30_000)
    #expect(batches.count > 1)
    #expect(batches.allSatisfy { korean[$0].joined(separator: " ").utf8.count <= 30_000 })
    #expect(batches.map(\.count).reduce(0, +) == korean.count)
    // One argument over the limit still goes, alone.
    #expect(AdbFileSystem.argumentBatches(["a", String(repeating: "x", count: 50), "b"], limit: 10) == [0..<1, 1..<2, 2..<3])
    #expect(AdbFileSystem.argumentBatches([], limit: 10).isEmpty)
}

@Test func deletePathsAreChecked() {
    #expect(AdbFileSystem.isSafeToDelete("/sdcard/Download/x"))
    #expect(!AdbFileSystem.isSafeToDelete("/"))
    #expect(!AdbFileSystem.isSafeToDelete("/sdcard"))
    #expect(!AdbFileSystem.isSafeToDelete("sdcard/Download"))
    #expect(!AdbFileSystem.isSafeToDelete("/sdcard/Download/.."))
    #expect(!AdbFileSystem.isSafeToDelete("/sdcard/./Download"))
    // Storages themselves.
    for root in ["/storage", "/storage/emulated", "/storage/emulated/0", "/storage/self/primary", "/storage/1234-ABCD"] {
        #expect(!AdbFileSystem.isSafeToDelete(root), "\(root)")
    }
    #expect(AdbFileSystem.isSafeToDelete("/storage/emulated/0/DCIM"))
    #expect(AdbFileSystem.isSafeToDelete("/storage/1234-ABCD/DCIM"))
}

@Test func adbTellsALostConnectionFromAMissingFile() {
    let fs = AdbFileSystem(client: AdbClient(), serial: "S", features: [])
    #expect(fs.isConnectionLoss(AdbError.connectionClosed))
    #expect(fs.isConnectionLoss(AdbError.failed("device 'S' not found")))
    #expect(!fs.isConnectionLoss(AdbError.remoteError(path: "/x", errno: 2)))
    #expect(fs.isNotFound(AdbError.remoteError(path: "/x", errno: 2)))
    #expect(fs.isNotFound(DeviceFSError.notFound("/x")))
    #expect(!fs.isNotFound(AdbError.remoteError(path: "/x", errno: 13)))
}

@Test func findsCardsAndUsbDrivesInMountTable() {
    let mounts = """
    /dev/block/dm-52 / ext4 ro,seclabel,relatime 0 0
    /dev/fuse /storage/emulated fuse rw,lazytime,nosuid,nodev,noexec,noatime 0 0
    /dev/block/vold/public:179,129 /mnt/media_rw/0C1E-1A0B vfat rw,dirsync,nosuid,nodev,noexec,noatime 0 0
    /dev/fuse /storage/0C1E-1A0B fuse rw,lazytime,nosuid,nodev,noexec,noatime 0 0
    /dev/block/vold/public:8,1 /mnt/media_rw/5E2F-11D3 exfat rw,dirsync,nosuid,nodev,noexec,noatime 0 0
    /dev/block/vold/public:179,129 /mnt/media_rw/0C1E-1A0B vfat rw 0 0
    /dev/block/vold/public:259,3 /mnt/media_rw/7A6B-0000 vfat rw 0 0
    """
    let found = AdbFileSystem.removableStorages(mounts: mounts)
    #expect(found.map(\.ref.path) == ["/storage/0C1E-1A0B", "/storage/5E2F-11D3", "/storage/7A6B-0000"])
    #expect(found.map(\.kind) == [.sdCard, .usbDrive, .other])
    #expect(AdbFileSystem.removableStorages(mounts: "/dev/fuse /storage/emulated fuse rw 0 0").isEmpty)
}

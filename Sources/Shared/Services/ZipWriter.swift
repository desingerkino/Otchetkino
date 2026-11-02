import Foundation

/// Минимальный ZIP-писатель (без сжатия, метод STORE). Достаточно для XLSX и резервных копий:
/// фотографии уже сжаты (JPEG/HEIC), а XML невелик.
struct ZipWriter {
    private struct Entry { var name: String; var crc: UInt32; var size: UInt32; var offset: UInt32; var dosTime: UInt16; var dosDate: UInt16 }
    private var body = Data()
    private var entries: [Entry] = []

    private static let crcTable: [UInt32] = (0..<256).map { i -> UInt32 in
        var c = UInt32(i)
        for _ in 0..<8 { c = (c & 1) != 0 ? (0xEDB88320 ^ (c >> 1)) : (c >> 1) }
        return c
    }

    static func crc32(_ data: Data) -> UInt32 {
        var c: UInt32 = 0xFFFFFFFF
        data.withUnsafeBytes { (buf: UnsafeRawBufferPointer) in
            for b in buf { c = crcTable[Int((c ^ UInt32(b)) & 0xFF)] ^ (c >> 8) }
        }
        return c ^ 0xFFFFFFFF
    }

    private static func dos(_ date: Date) -> (UInt16, UInt16) {
        let c = Calendar(identifier: .gregorian).dateComponents(in: TimeZone.current, from: date)
        let year = UInt16(max(1980, c.year ?? 1980) - 1980)
        let hour = UInt16(c.hour ?? 0)
        let minute = UInt16(c.minute ?? 0)
        let second = UInt16((c.second ?? 0) / 2)
        let month = UInt16(c.month ?? 1)
        let day = UInt16(c.day ?? 1)
        let time: UInt16 = (hour << 11) | (minute << 5) | second
        let dateBits: UInt16 = (year << 9) | (month << 5) | day
        return (time, dateBits)
    }

    private func le16(_ v: UInt16) -> [UInt8] { [UInt8(v & 0xFF), UInt8(v >> 8)] }
    private func le32(_ v: UInt32) -> [UInt8] { [UInt8(v & 0xFF), UInt8((v >> 8) & 0xFF), UInt8((v >> 16) & 0xFF), UInt8(v >> 24)] }

    mutating func add(name: String, data: Data, date: Date = Date()) {
        let nameData = Data(name.utf8)
        let crc = ZipWriter.crc32(data)
        let (t, d) = ZipWriter.dos(date)
        let entry = Entry(name: name, crc: crc, size: UInt32(data.count), offset: UInt32(body.count), dosTime: t, dosDate: d)
        var h = Data()
        h.append(contentsOf: le32(0x04034b50))
        h.append(contentsOf: le16(20))         // version needed
        h.append(contentsOf: le16(0x0800))     // UTF-8 имена
        h.append(contentsOf: le16(0))          // STORE
        h.append(contentsOf: le16(t))
        h.append(contentsOf: le16(d))
        h.append(contentsOf: le32(crc))
        h.append(contentsOf: le32(UInt32(data.count)))
        h.append(contentsOf: le32(UInt32(data.count)))
        h.append(contentsOf: le16(UInt16(nameData.count)))
        h.append(contentsOf: le16(0))
        h.append(nameData)
        body.append(h)
        body.append(data)
        entries.append(entry)
    }

    mutating func add(name: String, string: String) { add(name: name, data: Data(string.utf8)) }

    func finish() -> Data {
        var out = body
        let cdStart = out.count
        for e in entries {
            let nameData = Data(e.name.utf8)
            out.append(contentsOf: le32(0x02014b50))
            out.append(contentsOf: le16(20)); out.append(contentsOf: le16(20))
            out.append(contentsOf: le16(0x0800)); out.append(contentsOf: le16(0))
            out.append(contentsOf: le16(e.dosTime)); out.append(contentsOf: le16(e.dosDate))
            out.append(contentsOf: le32(e.crc)); out.append(contentsOf: le32(e.size)); out.append(contentsOf: le32(e.size))
            out.append(contentsOf: le16(UInt16(nameData.count)))
            out.append(contentsOf: le16(0)); out.append(contentsOf: le16(0)); out.append(contentsOf: le16(0)); out.append(contentsOf: le16(0))
            out.append(contentsOf: le32(0))
            out.append(contentsOf: le32(e.offset))
            out.append(nameData)
        }
        let cdSize = out.count - cdStart
        out.append(contentsOf: le32(0x06054b50))
        out.append(contentsOf: le16(0)); out.append(contentsOf: le16(0))
        out.append(contentsOf: le16(UInt16(entries.count))); out.append(contentsOf: le16(UInt16(entries.count)))
        out.append(contentsOf: le32(UInt32(cdSize)))
        out.append(contentsOf: le32(UInt32(cdStart)))
        out.append(contentsOf: le16(0))
        return out
    }
}

/// Чтение ZIP, созданного ZipWriter (только STORE) — нужно для восстановления из резервной копии.
enum ZipReader {
    static func read(_ data: Data) -> [String: Data]? {
        var result: [String: Data] = [:]
        let bytes = [UInt8](data)
        func u16(_ o: Int) -> Int { Int(bytes[o]) | (Int(bytes[o + 1]) << 8) }
        func u32(_ o: Int) -> Int { u16(o) | (u16(o + 2) << 16) }
        // найти конец центрального каталога
        guard bytes.count >= 22 else { return nil }
        var eocd = -1
        var i = bytes.count - 22
        while i >= 0 { if u32(i) == 0x06054b50 { eocd = i; break }; i -= 1 }
        guard eocd >= 0 else { return nil }
        let count = u16(eocd + 10)
        var p = u32(eocd + 16)
        for _ in 0..<count {
            guard p + 46 <= bytes.count, u32(p) == 0x02014b50 else { return nil }
            let method = u16(p + 10)
            let size = u32(p + 24)
            let nameLen = u16(p + 28), extraLen = u16(p + 30), commentLen = u16(p + 32)
            let localOffset = u32(p + 42)
            guard method == 0, p + 46 + nameLen <= bytes.count else { return nil }
            let name = String(decoding: bytes[(p + 46)..<(p + 46 + nameLen)], as: UTF8.self)
            guard localOffset + 30 <= bytes.count else { return nil }
            let lNameLen = u16(localOffset + 26), lExtraLen = u16(localOffset + 28)
            let start = localOffset + 30 + lNameLen + lExtraLen
            guard start + size <= bytes.count else { return nil }
            result[name] = data.subdata(in: start..<(start + size))
            p += 46 + nameLen + extraLen + commentLen
        }
        return result
    }
}

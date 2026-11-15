import Compression
import Foundation

/// zlib (RFC 1950) streams on top of the Compression framework.
///
/// PDF `/FlateDecode` data is a zlib stream, but `COMPRESSION_ZLIB` emits raw
/// DEFLATE, so the two-byte header and the Adler-32 trailer are written here.
public enum PDFZlib {
    /// Wraps `data` in a zlib stream: header, raw DEFLATE, Adler-32.
    public static func compress(_ data: Data) -> Data {
        var out = Data([0x78, 0x9C])
        out.append(deflate(data))
        out.append(adler32(data))
        return out
    }

    /// Inflates a zlib stream and checks its Adler-32 trailer. Returns nil for
    /// data that is not a valid zlib stream.
    public static func decompress(_ data: Data) -> Data? {
        guard data.count >= 6 else { return nil }
        let start = data.startIndex
        let cmf = data[start]
        let flg = data[start + 1]
        // CM must be 8 (DEFLATE) and the header must be a multiple of 31.
        guard cmf & 0x0F == 0x08, (UInt16(cmf) << 8 | UInt16(flg)) % 31 == 0 else { return nil }
        let payload = data[(start + 2)..<(data.endIndex - 4)]
        guard !payload.isEmpty else { return nil }
        let expected = UInt32(data[data.endIndex - 4]) << 24
            | UInt32(data[data.endIndex - 3]) << 16
            | UInt32(data[data.endIndex - 2]) << 8
            | UInt32(data[data.endIndex - 1])

        let chunkSize = 65536
        let buffer = UnsafeMutablePointer<UInt8>.allocate(capacity: chunkSize)
        defer { buffer.deallocate() }
        let decoded: Data? = payload.withUnsafeBytes { raw -> Data? in
            guard let source = raw.baseAddress?.assumingMemoryBound(to: UInt8.self) else { return nil }
            var stream = compression_stream(dst_ptr: buffer, dst_size: 0, src_ptr: source, src_size: 0,
                                            state: nil)
            guard compression_stream_init(&stream, COMPRESSION_STREAM_DECODE, COMPRESSION_ZLIB)
                == COMPRESSION_STATUS_OK else { return nil }
            defer { compression_stream_destroy(&stream) }
            stream.src_ptr = source
            stream.src_size = raw.count
            var output = Data()
            var status = COMPRESSION_STATUS_OK
            while status == COMPRESSION_STATUS_OK {
                stream.dst_ptr = buffer
                stream.dst_size = chunkSize
                status = compression_stream_process(&stream, Int32(COMPRESSION_STREAM_FINALIZE.rawValue))
                switch status {
                case COMPRESSION_STATUS_OK, COMPRESSION_STATUS_END:
                    output.append(buffer, count: chunkSize - stream.dst_size)
                default:
                    return nil
                }
            }
            return output
        }
        // The streaming decoder reports a corrupt stream as an error, so the
        // checksum only has to catch data that decodes to the wrong bytes.
        guard let decoded, checksum(decoded) == expected else { return nil }
        return decoded
    }

    /// Raw DEFLATE of `data`. The buffer starts at the worst case size for
    /// stored blocks and grows only if the encoder still reports failure.
    private static func deflate(_ data: Data) -> Data {
        var capacity = max(64, data.count + data.count / 1000 + 64)
        while capacity <= 1 << 30 {
            var output = Data(count: capacity)
            let written = output.withUnsafeMutableBytes { destination -> Int in
                guard let destination = destination.bindMemory(to: UInt8.self).baseAddress else { return 0 }
                return data.withUnsafeBytes { source -> Int in
                    // The encoder wants a valid source pointer even for empty input.
                    var empty: UInt8 = 0
                    return withUnsafePointer(to: &empty) { scratch in
                        compression_encode_buffer(destination, capacity,
                                                  source.bindMemory(to: UInt8.self).baseAddress ?? scratch,
                                                  data.count, nil, COMPRESSION_ZLIB)
                    }
                }
            }
            if written > 0 { return output.prefix(written) }
            capacity *= 2
        }
        return Data()
    }

    private static func adler32(_ data: Data) -> Data {
        let sum = checksum(data)
        return Data([UInt8(truncatingIfNeeded: sum >> 24), UInt8(truncatingIfNeeded: sum >> 16),
                     UInt8(truncatingIfNeeded: sum >> 8), UInt8(truncatingIfNeeded: sum)])
    }

    private static func checksum(_ data: Data) -> UInt32 {
        var a: UInt64 = 1
        var b: UInt64 = 0
        data.withUnsafeBytes { raw in
            var index = 0
            // Summing in 64-bit chunks keeps the per-byte work at one add each
            // and the reduction rare; the chunk size keeps b far from overflow.
            while index < raw.count {
                let end = min(index + 65536, raw.count)
                while index < end {
                    a += UInt64(raw[index])
                    b += a
                    index += 1
                }
                a %= 65521
                b %= 65521
            }
        }
        return UInt32(b) << 16 | UInt32(a)
    }
}

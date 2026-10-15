import Foundation

public extension UUID {
    /// The same UUID every time for the same text, such as a file's place on a device, so items read again keep
    /// their identity (and stay selected). Two 64-bit FNV-1a hashes, with the version and variant bits of a
    /// name-based UUID.
    init(stableFrom text: String) {
        func fnv(_ seed: UInt64) -> UInt64 {
            var hash = seed
            for byte in text.utf8 {
                hash ^= UInt64(byte)
                hash = hash &* 0x0000_0100_0000_01B3
            }
            return hash
        }
        var bytes = withUnsafeBytes(of: fnv(0xCBF2_9CE4_8422_2325).bigEndian, Array.init)
            + withUnsafeBytes(of: fnv(0x8422_2325_CBF2_9CE4).bigEndian, Array.init)
        bytes[6] = bytes[6] & 0x0F | 0x50
        bytes[8] = bytes[8] & 0x3F | 0x80
        self.init(uuid: (bytes[0], bytes[1], bytes[2], bytes[3], bytes[4], bytes[5], bytes[6], bytes[7],
                         bytes[8], bytes[9], bytes[10], bytes[11], bytes[12], bytes[13], bytes[14], bytes[15]))
    }
}

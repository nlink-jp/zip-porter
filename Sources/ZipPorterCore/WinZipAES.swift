import CommonCrypto
import Foundation

/// WinZip AES entry encryption (AE-1/AE-2, method 99 + 0x9901 extra field):
/// PBKDF2-HMAC-SHA1 (1000 iterations) key derivation, AES in CTR mode with a
/// little-endian counter starting at 1, and an HMAC-SHA1 authentication code
/// (first 10 bytes) over the ciphertext.
public struct WinZipAES {
    public static let authCodeSize = 10
    public static let pbkdf2Iterations: UInt32 = 1000

    public enum Mode { case encrypt, decrypt }

    private let mode: Mode
    private let encKey: [UInt8]
    private var hmac = CCHmacContext()
    /// The 2-byte password verifier derived alongside the keys; the writer
    /// stores it after the salt.
    public let derivedVerifier: Data

    /// CTR state: next block number (the counter starts at 1) and unused
    /// keystream bytes carried across chunk boundaries.
    private var nextBlock: UInt64 = 1
    private var pendingKeystream = Data()

    // MARK: - Init

    private init(password: String, strength: Zip.AESStrength, salt: Data, mode: Mode) {
        self.mode = mode
        let keyLen = strength.keyBytes
        var derived = [UInt8](repeating: 0, count: keyLen * 2 + 2)
        let passwordBytes = Array(password.utf8)
        salt.withUnsafeBytes { (saltRaw: UnsafeRawBufferPointer) in
            _ = CCKeyDerivationPBKDF(
                CCPBKDFAlgorithm(kCCPBKDF2),
                passwordBytes.map { CChar(bitPattern: $0) }, passwordBytes.count,
                saltRaw.bindMemory(to: UInt8.self).baseAddress, salt.count,
                CCPseudoRandomAlgorithm(kCCPRFHmacAlgSHA1),
                Self.pbkdf2Iterations,
                &derived, derived.count)
        }
        encKey = Array(derived[0..<keyLen])
        let authKey = Array(derived[keyLen..<(keyLen * 2)])
        derivedVerifier = Data(derived[(keyLen * 2)...])
        CCHmacInit(&hmac, CCHmacAlgorithm(kCCHmacAlgSHA1), authKey, authKey.count)
    }

    /// Decrypting init: verifies the stored 2-byte password verifier.
    /// Returns nil on (almost certainly) a wrong password — the verifier is
    /// 16 bits, so ~1/65536 wrong passwords pass here and fail the HMAC.
    public init?(password: String, strength: Zip.AESStrength, salt: Data, passwordVerifier: Data) {
        self.init(password: password, strength: strength, salt: salt, mode: .decrypt)
        guard derivedVerifier == passwordVerifier else { return nil }
    }

    /// Encrypting init. The caller provides a fresh random salt
    /// (`strength.saltBytes` long) and must store `derivedVerifier` after it.
    public init(encryptWith password: String, strength: Zip.AESStrength, salt: Data) {
        precondition(salt.count == strength.saltBytes)
        self.init(password: password, strength: strength, salt: salt, mode: .encrypt)
    }

    // MARK: - Streaming

    /// Transform one chunk. Decrypt mode HMACs the input (ciphertext);
    /// encrypt mode HMACs the output (ciphertext).
    public mutating func process(_ chunk: Data) -> Data {
        if mode == .decrypt { hmacUpdate(chunk) }
        let out = ctrXOR(chunk)
        if mode == .encrypt { hmacUpdate(out) }
        return out
    }

    /// Decrypt side: compare the entry's trailing auth code.
    public mutating func verifyAuthCode(_ trailer: Data) -> Bool {
        let mac = finalizeHMAC()
        guard trailer.count == Self.authCodeSize else { return false }
        var diff: UInt8 = 0
        for (a, b) in zip(mac.prefix(Self.authCodeSize), trailer) { diff |= a ^ b }
        return diff == 0
    }

    /// Encrypt side: the 10-byte auth code to append after the ciphertext.
    public mutating func authCode() -> Data {
        finalizeHMAC().prefix(Self.authCodeSize)
    }

    // MARK: - Internals

    private mutating func hmacUpdate(_ data: Data) {
        data.withUnsafeBytes { (raw: UnsafeRawBufferPointer) in
            guard let base = raw.baseAddress else { return }
            CCHmacUpdate(&hmac, base, raw.count)
        }
    }

    private mutating func finalizeHMAC() -> Data {
        var mac = [UInt8](repeating: 0, count: Int(CC_SHA1_DIGEST_LENGTH))
        CCHmacFinal(&hmac, &mac)
        return Data(mac)
    }

    /// XOR the input with AES-CTR keystream. Counter blocks are the 16-byte
    /// little-endian block number (WinZip's variant — NOT the NIST big-endian
    /// counter), encrypted with AES-ECB in bulk.
    private mutating func ctrXOR(_ input: Data) -> Data {
        var out = Data(capacity: input.count)
        var index = input.startIndex

        // Drain keystream left over from the previous chunk.
        while !pendingKeystream.isEmpty, index < input.endIndex {
            out.append(input[index] ^ pendingKeystream.removeFirst())
            index += 1
        }
        let remaining = input.distance(from: index, to: input.endIndex)
        guard remaining > 0 else { return out }

        let blocks = (remaining + 15) / 16
        var counters = [UInt8](repeating: 0, count: blocks * 16)
        for b in 0..<blocks {
            var n = (nextBlock + UInt64(b)).littleEndian
            withUnsafeBytes(of: &n) { counters.replaceSubrange(b * 16..<(b * 16 + 8), with: $0) }
        }
        nextBlock += UInt64(blocks)

        var keystream = [UInt8](repeating: 0, count: blocks * 16)
        var moved = 0
        let status = CCCrypt(
            CCOperation(kCCEncrypt),
            CCAlgorithm(kCCAlgorithmAES),
            CCOptions(kCCOptionECBMode),
            encKey, encKey.count,
            nil,
            counters, counters.count,
            &keystream, keystream.count,
            &moved)
        precondition(status == kCCSuccess && moved == keystream.count, "AES-ECB keystream failed")

        var k = 0
        while index < input.endIndex {
            out.append(input[index] ^ keystream[k])
            index += 1
            k += 1
        }
        if k < keystream.count {
            pendingKeystream = Data(keystream[k...])
        }
        return out
    }
}

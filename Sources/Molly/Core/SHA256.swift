import CryptoKit
import Foundation

enum SHA256 {
    static func hexPrefix(of text: String, bytes: Int) -> String {
        let digest = CryptoKit.SHA256.hash(data: Data(text.utf8))
        return digest.prefix(bytes).map { String(format: "%02x", $0) }.joined()
    }
}

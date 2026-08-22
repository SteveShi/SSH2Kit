import Foundation

public enum SSHAuth: Sendable {
    case password(String, remember: Bool)
    case publicKey(path: String, passphrase: String?)
}


import Foundation

/// WebKit canonicalizes host casing and default ports before asking its navigation delegate.
/// Compare origins semantically while keeping the terminal document confined to its host.
enum TerminalNavigation {
    static func allows(_ target: URL, document: URL) -> Bool {
        guard let scheme = document.scheme?.lowercased(), ["http", "https"].contains(scheme),
            let host = document.host?.lowercased(),
            target.scheme?.lowercased() == scheme,
            target.host?.lowercased() == host,
            target.user == nil, target.password == nil
        else { return false }
        let defaultPort = scheme == "https" ? 443 : 80
        return (target.port ?? defaultPort) == (document.port ?? defaultPort) && target.path == "/terminal"
    }
}

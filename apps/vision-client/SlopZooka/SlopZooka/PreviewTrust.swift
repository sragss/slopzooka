import Foundation
import Security

/// Trust only the paired companion's CA at this preview's exact HTTPS endpoint.
/// External navigation continues to use the system's ordinary certificate trust.
struct PreviewTrust {
    let endpoint: URL
    let authority: SecCertificate

    init?(endpoint: URL, certificateAuthority: String?) {
        guard endpoint.scheme == "https", let certificateAuthority,
            let data = Data(base64Encoded: certificateAuthority),
            let authority = SecCertificateCreateWithData(nil, data as CFData)
        else { return nil }
        self.endpoint = endpoint
        self.authority = authority
    }

    func matches(host: String, port: Int) -> Bool {
        let normalize: (String) -> String = { $0.trimmingCharacters(in: CharacterSet(charactersIn: "[]")).lowercased() }
        return normalize(host) == normalize(endpoint.host ?? "") && port == (endpoint.port ?? 443)
    }

    func evaluate(_ trust: SecTrust) -> Bool {
        guard let host = endpoint.host else { return false }
        let hostname = host.trimmingCharacters(in: CharacterSet(charactersIn: "[]"))
        guard SecTrustSetPolicies(trust, SecPolicyCreateSSL(true, hostname as CFString)) == errSecSuccess,
            SecTrustSetAnchorCertificates(trust, [authority] as CFArray) == errSecSuccess,
            SecTrustSetAnchorCertificatesOnly(trust, true) == errSecSuccess,
            SecTrustSetNetworkFetchAllowed(trust, false) == errSecSuccess
        else { return false }
        return SecTrustEvaluateWithError(trust, nil)
    }
}

import Foundation

/// One HTTP exchange, decoded far enough to decide what happens next.
struct RawResponse: Sendable {
    var status: Int
    var headers: [String: String]
    var data: Data

    var body: [String: JSONValue]? {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return nil
        }
        return object.mapValues(JSONValue.init)
    }

    /// The body as `JSONSerialization` hands it over, for the error decoder.
    var rawBody: [String: Any]? {
        try? JSONSerialization.jsonObject(with: data) as? [String: Any]
    }
}

/// Builds the session and carries the trust decision.
enum Transport {
    static func makeSession(_ configuration: AxoniumConfiguration) -> URLSession {
        let sessionConfiguration =
            configuration.sessionConfiguration ?? {
                // Ephemeral by default: no disk cache, no cookie jar, nothing written where a
                // backup or another process could read a prompt. An SDK inside somebody's app
                // should leave nothing behind it was not asked to leave.
                let config = URLSessionConfiguration.ephemeral
                config.timeoutIntervalForRequest = configuration.timeouts.request
                config.timeoutIntervalForResource = configuration.timeouts.request
                return config
            }()

        guard !configuration.additionalTrustAnchors.isEmpty else {
            return URLSession(configuration: sessionConfiguration)
        }
        let delegate = PinnedTrustDelegate(anchors: configuration.additionalTrustAnchors)
        return URLSession(
            configuration: sessionConfiguration, delegate: delegate, delegateQueue: nil)
    }

    static func headers(_ response: HTTPURLResponse) -> [String: String] {
        var headers: [String: String] = [:]
        for (key, value) in response.allHeaderFields {
            if let key = key as? String, let value = value as? String { headers[key] = value }
        }
        return headers
    }

    /// The wait the platform asked for, header first.
    ///
    /// The header wins where both exist. The platform states the two are written from one
    /// variable in one call and cannot disagree today; the precedence is what protects the next
    /// envelope that carries only one of them.
    static func retryAfter(headers: [String: String], body: [String: Any]?) -> Double? {
        let lookup = Dictionary(
            headers.map { ($0.key.lowercased(), $0.value) }, uniquingKeysWith: { _, last in last })
        if let raw = lookup["retry-after"], let seconds = Double(raw) { return seconds }
        return (body?["retry_after"] as? NSNumber)?.doubleValue
    }
}

/// Trusts a private CA **in addition to** the system's.
///
/// Additional, never instead: the anchors are appended and `SecTrustEvaluateWithError` still has
/// to succeed. There is no code path here that returns a credential without evaluating trust,
/// which is the shape every "just disable verification for dev" bug takes.
final class PinnedTrustDelegate: NSObject, URLSessionDelegate, @unchecked Sendable {
    private let anchors: [SecCertificate]

    init(anchors: [Data]) {
        self.anchors = anchors.compactMap { data in
            // DER first; a PEM is the same bytes wrapped in base64 and a header.
            if let certificate = SecCertificateCreateWithData(nil, data as CFData) {
                return certificate
            }
            guard let text = String(data: data, encoding: .utf8) else { return nil }
            let body =
                text
                .replacingOccurrences(of: "-----BEGIN CERTIFICATE-----", with: "")
                .replacingOccurrences(of: "-----END CERTIFICATE-----", with: "")
                .replacingOccurrences(of: "\n", with: "")
                .replacingOccurrences(of: "\r", with: "")
            guard let der = Data(base64Encoded: body) else { return nil }
            return SecCertificateCreateWithData(nil, der as CFData)
        }
    }

    func urlSession(
        _ session: URLSession, didReceive challenge: URLAuthenticationChallenge,
        completionHandler: @escaping @Sendable (
            URLSession.AuthChallengeDisposition, URLCredential?
        ) -> Void
    ) {
        guard challenge.protectionSpace.authenticationMethod == NSURLAuthenticationMethodServerTrust,
            let trust = challenge.protectionSpace.serverTrust
        else {
            completionHandler(.performDefaultHandling, nil)
            return
        }

        SecTrustSetAnchorCertificates(trust, anchors as CFArray)
        // false, so the system's own roots keep working. A deployment with a private CA for
        // staging and a real one for production must not need two clients.
        SecTrustSetAnchorCertificatesOnly(trust, false)

        var error: CFError?
        if SecTrustEvaluateWithError(trust, &error) {
            completionHandler(.useCredential, URLCredential(trust: trust))
        } else {
            completionHandler(.cancelAuthenticationChallenge, nil)
        }
    }
}

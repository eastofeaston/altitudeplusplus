import AVFoundation
import Foundation

/// Answers FairPlay key requests for one playback session using Altitude+'s
/// Axinom license service.
///
/// Flow (same as Safari on altitudeplus.com and Axinom's iOS sample):
/// 1. Download the FairPlay application certificate from `certificateUrl`.
/// 2. Build the SPC with the content ID taken from the `skd://` key URI.
/// 3. POST the raw SPC to `licenseUrl` with the `X-AxDRM-Message` license token.
/// 4. Hand the raw CKC back to AVFoundation. Decryption stays inside Apple's
///    FairPlay module; the app never sees content keys or decrypted media.
final class FairPlayKeyDelivery: NSObject, AVContentKeySessionDelegate {
    enum KeyError: LocalizedError {
        case badKeyIdentifier
        case certificate(Int)
        case license(Int, String)

        var errorDescription: String? {
            switch self {
            case .badKeyIdentifier:
                return "The stream used an unexpected FairPlay key format."
            case .certificate(let status):
                return "Couldn't download the FairPlay certificate (HTTP \(status))."
            case .license(let status, let body):
                return "The license server refused playback (HTTP \(status)). \(body)"
            }
        }
    }

    /// The Simulator has no FairPlay support, and creating a FairPlay
    /// AVContentKeySession there raises an Objective-C exception that aborts
    /// the app (Swift can't catch it), so check before constructing one.
    static var isSupported: Bool {
        #if targetEnvironment(simulator)
        return false
        #else
        return true
        #endif
    }

    private let info: FairPlayInfo
    private let session = AVContentKeySession(keySystem: .fairPlayStreaming)
    private let queue = DispatchQueue(label: "com.altitudeplusplus.fairplay")
    private var certificate: Data?

    /// Called on the main queue when a key request fails for good.
    var onFailure: ((Error) -> Void)?

    init(info: FairPlayInfo) {
        self.info = info
        super.init()
        session.setDelegate(self, queue: queue)
    }

    func attach(to asset: AVURLAsset) {
        session.addContentKeyRecipient(asset)
    }

    // MARK: AVContentKeySessionDelegate

    func contentKeySession(_ session: AVContentKeySession, didProvide keyRequest: AVContentKeyRequest) {
        handle(keyRequest)
    }

    func contentKeySession(_ session: AVContentKeySession, didProvideRenewingContentKeyRequest keyRequest: AVContentKeyRequest) {
        handle(keyRequest)
    }

    func contentKeySession(_ session: AVContentKeySession, contentKeyRequest keyRequest: AVContentKeyRequest, didFailWithError error: Error) {
        report(error)
    }

    func contentKeySession(
        _ session: AVContentKeySession,
        shouldRetry keyRequest: AVContentKeyRequest,
        reason retryReason: AVContentKeyRequest.RetryReason
    ) -> Bool {
        switch retryReason {
        case .timedOut, .receivedResponseWithExpiredLease, .receivedObsoleteContentKey:
            return true
        default:
            return false
        }
    }

    // MARK: Key exchange

    private func handle(_ keyRequest: AVContentKeyRequest) {
        guard let identifier = keyRequest.identifier as? String, identifier.hasPrefix("skd://") else {
            keyRequest.processContentKeyResponseError(KeyError.badKeyIdentifier)
            report(KeyError.badKeyIdentifier)
            return
        }
        let contentId = Data(identifier.dropFirst("skd://".count).utf8)

        Task {
            do {
                let certificate = try await loadCertificate()
                let spc = try await makeSPC(for: keyRequest, certificate: certificate, contentId: contentId)
                let ckc = try await requestLicense(spc: spc)
                keyRequest.processContentKeyResponse(AVContentKeyResponse(fairPlayStreamingKeyResponseData: ckc))
            } catch {
                keyRequest.processContentKeyResponseError(error)
                report(error)
            }
        }
    }

    private func makeSPC(for keyRequest: AVContentKeyRequest, certificate: Data, contentId: Data) async throws -> Data {
        try await withCheckedThrowingContinuation { continuation in
            keyRequest.makeStreamingContentKeyRequestData(
                forApp: certificate,
                contentIdentifier: contentId,
                options: [AVContentKeyRequestProtocolVersionsKey: [1]]
            ) { data, error in
                if let data {
                    continuation.resume(returning: data)
                } else {
                    continuation.resume(throwing: error ?? KeyError.badKeyIdentifier)
                }
            }
        }
    }

    private func loadCertificate() async throws -> Data {
        if let certificate = queue.sync(execute: { self.certificate }) {
            return certificate
        }
        let (data, response) = try await URLSession.shared.data(from: info.certificateURL)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard status == 200, !data.isEmpty else { throw KeyError.certificate(status) }

        // Some services serve the DER certificate base64-encoded.
        var certificate = data
        if let text = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines),
           text.hasPrefix("MII"), let decoded = Data(base64Encoded: text) {
            certificate = decoded
        }
        queue.sync { self.certificate = certificate }
        return certificate
    }

    private func requestLicense(spc: Data) async throws -> Data {
        var request = URLRequest(url: info.licenseURL)
        request.httpMethod = "POST"
        request.httpBody = spc
        request.setValue("application/octet-stream", forHTTPHeaderField: "Content-Type")
        if let token = info.licenseToken {
            request.setValue(token, forHTTPHeaderField: "X-AxDRM-Message")
        }
        let (data, response) = try await URLSession.shared.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard status == 200, !data.isEmpty else {
            let body = String(data: data.prefix(300), encoding: .utf8) ?? ""
            throw KeyError.license(status, body)
        }
        return data
    }

    private func report(_ error: Error) {
        DispatchQueue.main.async { [weak self] in
            self?.onFailure?(error)
        }
    }
}

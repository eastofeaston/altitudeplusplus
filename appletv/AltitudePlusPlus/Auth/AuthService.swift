import Foundation
import UIKit

struct UserSession: Codable, Equatable {
    var authorizationToken: String
    var refreshToken: String
    var userId: String?
    var email: String?
    var isSubscribed: Bool?

    var expiresAt: Date? { JWT.expiry(of: authorizationToken) }
}

enum JWT {
    static func payload(of token: String) -> [String: Any]? {
        let parts = token.split(separator: ".")
        guard parts.count >= 2 else { return nil }
        var base64 = String(parts[1]).replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        base64 += String(repeating: "=", count: (4 - base64.count % 4) % 4)
        guard let data = Data(base64Encoded: base64) else { return nil }
        return (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
    }

    static func expiry(of token: String) -> Date? {
        guard let exp = payload(of: token)?["exp"] as? Double else { return nil }
        return Date(timeIntervalSince1970: exp)
    }
}

/// Passwordless email sign-in (the same OTP flow altitudeplus.com uses) and
/// token lifecycle.
@MainActor
final class AuthService {
    private let client = ViewLiftClient()
    private let sessionAccount = "session"
    private let deviceIdAccount = "deviceId"

    private(set) var session: UserSession?
    private var anonymousToken: String?

    init() {
        if let data = Keychain.data(for: sessionAccount),
           let saved = try? JSONDecoder().decode(UserSession.self, from: data) {
            session = saved
        }
    }

    /// Stable per-install identifier, kept in the Keychain so it survives reinstalls.
    var deviceId: String {
        if let data = Keychain.data(for: deviceIdAccount), let id = String(data: data, encoding: .utf8) {
            return id
        }
        let id = UUID().uuidString.lowercased()
        Keychain.set(Data(id.utf8), for: deviceIdAccount)
        return id
    }

    // MARK: Sign-in

    /// Step 1: Altitude+ emails a one-time code. Returns the key needed to validate it.
    func sendCode(to email: String, profile: DeviceProfile) async throws -> String {
        let token = try await anonymousAuthorization(profile: profile)
        let mutation = """
        mutation ($site: String!, $device: EntitlementDevice!, $input: IdentityAuthOtpInitiateInput!) {
          identityAuthOtpInitiate(site: $site, device: $device, input: $input) { key }
        }
        """
        let device = UIDevice.current
        let appVersion = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0"
        // Validation copies these from the initiate request into string fields
        // server-side; leaving any out makes the validate step fail after the
        // code is accepted. The website always sends the campaign fields, even empty.
        let variables: [String: Any] = [
            "site": AltitudeConfig.site,
            "device": profile.deviceType,
            "input": [
                "email": email,
                "deviceName": device.name,
                "campaign": "",
                "campaignSource": "",
                "campaignMedium": "",
                "deviceMetadata": [
                    "manufacturerName": "Apple",
                    "modelName": device.model,
                    "osName": device.systemName,
                    "osVersion": device.systemVersion,
                    "manufacturingYear": "",
                    "serialNumber": deviceId,
                    "userAgent": "AltitudePlusPlus/\(appVersion) \(device.systemName)/\(device.systemVersion)",
                ],
            ],
        ]
        let data = try await client.graphQL(mutation, variables: variables, token: token)
        guard let key = data["identityAuthOtpInitiate"]?["key"]?.string else {
            throw ViewLiftError(message: "Altitude+ didn't accept that email address.")
        }
        return key
    }

    /// Step 2: exchange the emailed code for user tokens.
    func verify(code: String, key: String, email: String, profile: DeviceProfile) async throws -> UserSession {
        let token = try await anonymousAuthorization(profile: profile)
        let mutation = """
        mutation ($site: String!, $key: String, $otp: String) {
          identityAuthOtpValidate(site: $site, key: $key, otp: $otp) {
            userId refreshToken email authorizationToken isSubscribed
          }
        }
        """
        let data = try await client.graphQL(
            mutation,
            variables: ["site": AltitudeConfig.site, "key": key, "otp": code],
            token: token
        )
        guard let result = data["identityAuthOtpValidate"],
              let authorization = result["authorizationToken"]?.string,
              let refresh = result["refreshToken"]?.string else {
            throw ViewLiftError(message: "That code didn't work. Request a new one and try again.")
        }
        let session = UserSession(
            authorizationToken: authorization,
            refreshToken: refresh,
            userId: result["userId"]?.string,
            email: result["email"]?.string ?? email,
            isSubscribed: result["isSubscribed"]?.bool
        )
        store(session)
        return session
    }

    func signOut(profile: DeviceProfile) {
        if let token = session?.authorizationToken {
            let client = client
            Task.detached {
                _ = try? await client.post(
                    "identity/signout",
                    query: ["site": AltitudeConfig.site, "platform": profile.deviceType],
                    token: token
                )
            }
        }
        session = nil
        Keychain.remove(sessionAccount)
    }

    // MARK: Tokens

    /// A user token that is valid for at least the next few minutes.
    func validAuthorization(profile: DeviceProfile) async throws -> String {
        guard let current = session else {
            throw ViewLiftError(code: "SIGNED_OUT", message: "Sign in to Altitude+ to watch.")
        }
        if let expiry = current.expiresAt, expiry.timeIntervalSinceNow > 300 {
            return current.authorizationToken
        }
        return try await refresh(profile: profile).authorizationToken
    }

    @discardableResult
    func refresh(profile: DeviceProfile) async throws -> UserSession {
        guard var current = session else {
            throw ViewLiftError(code: "SIGNED_OUT", message: "Sign in to Altitude+ to watch.")
        }
        let mutation = """
        mutation ($site: String!, $device: EntitlementDevice!, $refreshToken: String!) {
          identityRefreshToken(site: $site, device: $device, refreshToken: $refreshToken) {
            authorizationToken refreshToken userId
          }
        }
        """
        do {
            let data = try await client.graphQL(
                mutation,
                variables: ["site": AltitudeConfig.site, "device": profile.deviceType, "refreshToken": current.refreshToken],
                token: current.authorizationToken
            )
            guard let result = data["identityRefreshToken"],
                  let authorization = result["authorizationToken"]?.string else {
                throw ViewLiftError(message: "Token refresh returned no token")
            }
            current.authorizationToken = authorization
            current.refreshToken = result["refreshToken"]?.string ?? current.refreshToken
        } catch {
            // The website refreshes through REST; try that before giving up.
            let json = try await client.get("identity/refresh/\(current.refreshToken)", token: nil)
            guard let authorization = json["authorizationToken"]?.string else {
                session = nil
                Keychain.remove(sessionAccount)
                throw ViewLiftError(code: "SIGNED_OUT", message: "Your Altitude+ sign-in expired. Please sign in again.")
            }
            current.authorizationToken = authorization
            current.refreshToken = json["refreshToken"]?.string ?? current.refreshToken
        }
        store(current)
        return current
    }

    /// Anonymous token the website uses before sign-in (needed to call the OTP mutations).
    func anonymousAuthorization(profile: DeviceProfile) async throws -> String {
        if let token = anonymousToken, let expiry = JWT.expiry(of: token), expiry.timeIntervalSinceNow > 300 {
            return token
        }
        let json = try await client.get(
            "identity/anonymous-token",
            query: ["site": AltitudeConfig.site, "platform": profile.deviceType, "deviceId": deviceId],
            token: nil
        )
        guard let token = json["authorizationToken"]?.string else {
            throw ViewLiftError(message: "Couldn't reach Altitude+. Check your internet connection.")
        }
        anonymousToken = token
        return token
    }

    private func store(_ session: UserSession) {
        self.session = session
        if let data = try? JSONEncoder().encode(session) {
            Keychain.set(data, for: sessionAccount)
        }
    }
}

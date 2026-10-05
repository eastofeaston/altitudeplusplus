import SwiftUI

/// Passwordless sign-in: Altitude+ emails a one-time code.
struct SignInView: View {
    @Environment(AppModel.self) private var model

    @State private var email = ""
    @State private var code = ""
    @State private var otpKey: String?
    @State private var isWorking = false
    @State private var errorText: String?
    @FocusState private var focus: Field?

    private enum Field { case email, code }

    var body: some View {
        VStack(spacing: 40) {
            VStack(spacing: 12) {
                Text("Altitude+")
                    .font(.system(size: 76, weight: .heavy))
                Text(otpKey == nil
                     ? "Sign in with the email on your Altitude+ account."
                     : "We sent a code to \(email). Enter it below.")
                    .font(.title3)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }

            if otpKey == nil {
                TextField("Email address", text: $email)
                    .textContentType(.emailAddress)
                    .keyboardType(.emailAddress)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .focused($focus, equals: .email)
                    .onSubmit(sendCode)
                    .frame(width: 900)

                Button(action: sendCode) {
                    label("Email Me a Code")
                }
                .disabled(!isValidEmail || isWorking)
            } else {
                TextField("Code", text: $code)
                    .textContentType(.oneTimeCode)
                    .keyboardType(.numberPad)
                    .focused($focus, equals: .code)
                    .onSubmit(verify)
                    .frame(width: 500)

                HStack(spacing: 40) {
                    Button(action: verify) {
                        label("Sign In")
                    }
                    .disabled(code.trimmingCharacters(in: .whitespaces).isEmpty || isWorking)

                    Button("Send a New Code", action: sendCode)
                        .disabled(isWorking)

                    Button("Use a Different Email") {
                        otpKey = nil
                        code = ""
                        errorText = nil
                        focus = .email
                    }
                    .disabled(isWorking)
                }
            }

            if let errorText {
                Text(errorText)
                    .foregroundStyle(.red)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 1100)
            }

            Text("Tip: an iPhone nearby can fill in the keyboard for you.")
                .font(.caption)
                .foregroundStyle(.tertiary)
        }
        .padding(80)
        .onAppear { focus = .email }
    }

    private func label(_ title: String) -> some View {
        HStack(spacing: 16) {
            if isWorking { ProgressView() }
            Text(title)
        }
        .frame(minWidth: 360)
    }

    private var isValidEmail: Bool {
        let trimmed = email.trimmingCharacters(in: .whitespaces)
        return trimmed.contains("@") && trimmed.contains(".")
    }

    private func sendCode() {
        guard isValidEmail, !isWorking else { return }
        email = email.trimmingCharacters(in: .whitespaces)
        isWorking = true
        errorText = nil
        Task {
            defer { isWorking = false }
            do {
                otpKey = try await model.auth.sendCode(to: email, profile: model.profile)
                code = ""
                focus = .code
            } catch {
                errorText = error.localizedDescription
            }
        }
    }

    private func verify() {
        guard let otpKey, !isWorking else { return }
        let trimmed = code.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return }
        isWorking = true
        errorText = nil
        Task {
            defer { isWorking = false }
            do {
                _ = try await model.auth.verify(code: trimmed, key: otpKey, email: email, profile: model.profile)
                await model.didSignIn()
            } catch {
                errorText = error.localizedDescription
            }
        }
    }
}

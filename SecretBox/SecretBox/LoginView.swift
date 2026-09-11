import SwiftUI

struct LoginView: View {
    @ObservedObject var model: SecretBoxAppModel
    @State private var username: String = ""
    @State private var password: String = ""
    @Environment(\.colorScheme) var scheme

    var body: some View {
        VStack {
            Spacer()
            VStack(spacing: 20) {
                Text("Login")
                    .font(.title2.weight(.semibold))

                TextField("Username", text: $username)
                    .textFieldStyle(.roundedBorder)
                    .accessibilityIdentifier("login.username")

                SecureField("Password", text: $password)
                    .textFieldStyle(.roundedBorder)
                    .accessibilityIdentifier("login.password")

                Button(action: {
                    withAnimation {
                        model.signIn(username, password)
                    }
                }) {
                    Text("Sign In")
                        .foregroundColor(.white)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 10)
                        .background(
                            RoundedRectangle(cornerRadius: 14, style: .continuous)
                                .fill(AppTheme.brand)
                        )
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier("login.signIn")
            }
            .padding(30)
            .background(
                RoundedRectangle(cornerRadius: 24, style: .continuous)
                    .fill(AppTheme.cardBackground(scheme))
                    .overlay(
                        RoundedRectangle(cornerRadius: 24, style: .continuous)
                            .stroke(AppTheme.border(scheme))
                    )
            )
            .padding(.horizontal, 20)
            Spacer()
        }
        .background(AppTheme.surfaceBackground(scheme))
        .ignoresSafeArea()
    }
}

#if DEBUG
struct LoginView_Previews: PreviewProvider {
    static var previews: some View {
        LoginView(model: previewModel())
            .preferredColorScheme(.light)
        LoginView(model: previewModel())
            .preferredColorScheme(.dark)
    }

    private static func previewModel() -> SecretBoxAppModel {
        let model = SecretBoxAppModel()
        model.isAuthenticated = false
        return model
    }
}
#endif

import SwiftUI
import WebKit

/// A sign-in page in a WKWebView, as an app's own web login screen would show it. The web view
/// keeps the default `isInspectable = false`: agent mode must read it without Web Inspector.
/// When the form is submitted the page reports what it received to the native status line, so a
/// test can check the result without reading the page.
struct WebSignInView: View {
    @State private var status = "Loading"

    var body: some View {
        VStack(spacing: 0) {
            Text("Status: \(status)")
                .font(.footnote)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 16)
                .padding(.vertical, 8)
                .accessibilityIdentifier("web-sign-in.status")
                .accessibilityValue(status)
            WebSignInPage(status: $status)
        }
        .navigationTitle("Web Sign In")
        .navigationBarTitleDisplayMode(.inline)
    }
}

private struct WebSignInPage: UIViewRepresentable {
    @Binding var status: String

    func makeCoordinator() -> Coordinator { Coordinator(status: $status) }

    func makeUIView(context: Context) -> WKWebView {
        let configuration = WKWebViewConfiguration()
        configuration.userContentController.add(context.coordinator, name: "signIn")
        configuration.websiteDataStore = .nonPersistent()
        let view = WKWebView(frame: .zero, configuration: configuration)
        view.navigationDelegate = context.coordinator
        view.accessibilityIdentifier = "web-sign-in.webview"
        view.loadHTMLString(Self.page, baseURL: URL(string: "https://playground.axe.invalid/"))
        return view
    }

    func updateUIView(_ view: WKWebView, context: Context) {}

    final class Coordinator: NSObject, WKScriptMessageHandler, WKNavigationDelegate {
        private let status: Binding<String>
        init(status: Binding<String>) { self.status = status }

        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            if status.wrappedValue == "Loading" { status.wrappedValue = "Ready" }
        }

        func userContentController(_ controller: WKUserContentController, didReceive message: WKScriptMessage) {
            guard let body = message.body as? [String: Any] else { return }
            switch body["event"] as? String {
            case "signIn":
                let email = body["email"] as? String ?? ""
                let length = body["passwordLength"] as? Int ?? 0
                let remember = body["remember"] as? Bool == true ? "on" : "off"
                status.wrappedValue = "Signed in: \(email), password \(length) characters, remember \(remember)"
            case "signOut":
                status.wrappedValue = "Signed out"
            case "invalid":
                status.wrappedValue = "Sign-in refused: \(body["reason"] as? String ?? "")"
            default:
                break
            }
        }
    }

    static let page = """
    <!doctype html>
    <html><head>
    <meta name="viewport" content="width=device-width,initial-scale=1">
    <title>Playground Sign In</title>
    <style>
    body { font: 17px -apple-system; margin: 16px; color: #1c1c1e; }
    h1 { font-size: 26px; margin: 0 0 4px; }
    p.lead { color: #6e6e73; margin: 0 0 12px; }
    input[type=email], input[type=password] { display: block; width: 100%; box-sizing: border-box;
      font-size: 17px; padding: 8px; margin: 4px 0 10px; border: 1px solid #c7c7cc; border-radius: 8px; }
    label.check { display: flex; align-items: center; gap: 8px; margin-bottom: 12px; }
    button { font-size: 17px; padding: 8px 18px; border: 0; border-radius: 8px; background: #0a84ff; color: white; }
    a { color: #0a84ff; }
    </style></head>
    <body>
    <main id="signin">
      <h1>Sign in</h1>
      <p class="lead">Use your Playground account.</p>
      <form id="form">
        <label for="email">Email</label>
        <input id="email" type="email" aria-label="Email" autocomplete="username">
        <label for="password">Password</label>
        <input id="password" type="password" aria-label="Password" autocomplete="current-password">
        <label class="check"><input id="remember" type="checkbox" aria-label="Remember me"> Remember me</label>
        <button id="submit" type="submit">Sign in</button>
      </form>
      <p><a href="#forgot" id="forgot">Forgot password?</a></p>
    </main>
    <main id="welcome" hidden>
      <h1 id="greeting">Welcome</h1>
      <p>You are signed in.</p>
      <button id="signout" type="button">Sign out</button>
    </main>
    <script>
    const post = (body) => window.webkit.messageHandlers.signIn.postMessage(body);
    document.getElementById('form').addEventListener('submit', (event) => {
      event.preventDefault();
      const email = document.getElementById('email').value;
      const password = document.getElementById('password').value;
      if (!email || !password) { post({event: 'invalid', reason: 'missing email or password'}); return; }
      post({event: 'signIn', email: email, passwordLength: password.length,
            remember: document.getElementById('remember').checked});
      document.getElementById('greeting').textContent = 'Welcome, ' + email;
      document.getElementById('signin').hidden = true;
      document.getElementById('welcome').hidden = false;
    });
    document.getElementById('signout').addEventListener('click', () => {
      post({event: 'signOut'});
      document.getElementById('form').reset();
      document.getElementById('welcome').hidden = true;
      document.getElementById('signin').hidden = false;
    });
    </script>
    </body></html>
    """
}

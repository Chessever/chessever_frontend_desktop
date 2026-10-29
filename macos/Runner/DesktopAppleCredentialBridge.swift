import AuthenticationServices
import Cocoa
import FlutterMacOS

/// AuthenticationServices owns credential state. No Apple token is stored here.
final class DesktopAppleCredentialBridge {
  static let shared = DesktopAppleCredentialBridge()
  private var channels: [FlutterMethodChannel] = []
  private var observer: NSObjectProtocol?

  private init() {}

  func attach(binaryMessenger: FlutterBinaryMessenger) {
    guard Bundle.main.object(forInfoDictionaryKey: "ChessEverAppStoreBuild") as? String == "YES"
    else { return }
    let channel = FlutterMethodChannel(
      name: "chessever.desktop/apple_credentials", binaryMessenger: binaryMessenger
    )
    channels.append(channel)
    channel.setMethodCallHandler { call, result in
      guard call.method == "getCredentialState" else {
        result(FlutterMethodNotImplemented)
        return
      }
      guard let args = call.arguments as? [String: Any],
            let userId = args["userId"] as? String, !userId.isEmpty else {
        result(FlutterError(code: "invalid_request", message: "Missing Apple identity.", details: nil))
        return
      }
      ASAuthorizationAppleIDProvider().getCredentialState(forUserID: userId) { state, error in
        DispatchQueue.main.async {
          guard error == nil else {
            result(FlutterError(code: "credential_state_unavailable", message: "Unable to check Apple credential state.", details: nil))
            return
          }
          switch state {
          case .authorized: result("authorized")
          case .revoked: result("revoked")
          case .notFound: result("notFound")
          case .transferred: result("transferred")
          @unknown default: result("unknown")
          }
        }
      }
    }
    if observer == nil {
      observer = NotificationCenter.default.addObserver(
        forName: ASAuthorizationAppleIDProvider.credentialRevokedNotification,
        object: nil, queue: .main
      ) { [weak self] _ in
        self?.channels.forEach { $0.invokeMethod("credentialRevoked", arguments: nil) }
      }
    }
  }
}

import AuthenticationServices
import Cocoa
import FlutterMacOS

/// Shows OAuth pages in an ASWebAuthenticationSession sheet.
///
/// Mac App Store edition only: App Review requires sign-in to finish without
/// sending the user to their default browser (guideline 4). Website builds
/// never attach the channel and keep opening the browser from Dart.
final class DesktopWebAuthBridge: NSObject, ASWebAuthenticationPresentationContextProviding {
  static let shared = DesktopWebAuthBridge()

  private static let canceled = FlutterError(
    code: "canceled", message: "Sign-in was canceled.", details: nil
  )

  private var channels: [FlutterMethodChannel] = []
  private var attempt: Attempt?
  private var isStore: Bool {
    Bundle.main.object(forInfoDictionaryKey: "ChessEverAppStoreBuild") as? String == "YES"
  }

  func attach(binaryMessenger: FlutterBinaryMessenger) {
    guard isStore else { return }
    let channel = FlutterMethodChannel(
      name: "chessever.desktop/web_auth", binaryMessenger: binaryMessenger
    )
    channel.setMethodCallHandler { [weak self] call, result in
      guard let self else {
        result(FlutterMethodNotImplemented)
        return
      }
      switch call.method {
      case "start":
        self.start(call.arguments, result: result)
      case "cancel":
        self.attempt?.session?.cancel()
        self.attempt?.finish(Self.canceled)
        result(nil)
      default:
        result(FlutterMethodNotImplemented)
      }
    }
    channels.append(channel)
  }

  private func start(_ arguments: Any?, result: @escaping FlutterResult) {
    guard let args = arguments as? [String: Any],
          let raw = args["url"] as? String, let url = URL(string: raw),
          let scheme = args["callbackScheme"] as? String, !scheme.isEmpty
    else {
      result(FlutterError(
        code: "bad_arguments", message: "url and callbackScheme are required.", details: nil
      ))
      return
    }
    // One sign-in at a time: a new request replaces a sheet still showing.
    attempt?.session?.cancel()
    attempt?.finish(Self.canceled)

    let attempt = Attempt(result: result)
    self.attempt = attempt
    let completion: (URL?, Error?) -> Void = { callbackURL, error in
      DispatchQueue.main.async {
        if let callbackURL {
          attempt.finish(callbackURL.absoluteString)
        } else if let error = error as? ASWebAuthenticationSessionError,
                  error.code == .canceledLogin {
          attempt.finish(Self.canceled)
        } else {
          attempt.finish(FlutterError(
            code: "failed",
            message: error?.localizedDescription ?? "Sign-in failed.",
            details: nil
          ))
        }
      }
    }
    let session: ASWebAuthenticationSession
    if #available(macOS 14.4, *) {
      session = ASWebAuthenticationSession(
        url: url, callback: .customScheme(scheme), completionHandler: completion
      )
    } else {
      session = ASWebAuthenticationSession(
        url: url, callbackURLScheme: scheme, completionHandler: completion
      )
    }
    session.presentationContextProvider = self
    // Share Safari's cookies so an account that is already signed in is offered.
    session.prefersEphemeralWebBrowserSession = false
    attempt.session = session
    if !session.start() {
      attempt.finish(FlutterError(
        code: "unavailable", message: "Could not open the sign-in window.", details: nil
      ))
    }
  }

  func presentationAnchor(for session: ASWebAuthenticationSession) -> ASPresentationAnchor {
    NSApp.keyWindow ?? NSApp.mainWindow ?? NSApp.windows.first ?? ASPresentationAnchor()
  }

  /// Answers one Dart call exactly once, whichever of completion, cancel or
  /// replacement happens first. Dropping the session breaks the
  /// session -> completion -> attempt cycle.
  private final class Attempt {
    var session: ASWebAuthenticationSession?
    private var result: FlutterResult?

    init(result: @escaping FlutterResult) {
      self.result = result
    }

    func finish(_ value: Any?) {
      guard let result else { return }
      self.result = nil
      session = nil
      result(value)
    }
  }
}

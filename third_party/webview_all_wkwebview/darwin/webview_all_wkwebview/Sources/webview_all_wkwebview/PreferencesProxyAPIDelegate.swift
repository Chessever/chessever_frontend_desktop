// Copyright 2013 The Flutter Authors
// Use of this source code is governed by a BSD-style license that can be
// found in the LICENSE file.

import WebKit

/// ProxyApi implementation for `WKPreferences`.
///
/// This class may handle instantiating native object instances that are attached to a Dart instance
/// or handle method calls on the associated native class or an instance of that class.
class PreferencesProxyAPIDelegate: PigeonApiDelegateWKPreferences {
  func setJavaScriptEnabled(
    pigeonApi: PigeonApiWKPreferences, pigeonInstance: WKPreferences, enabled: Bool
  ) throws {
    if #available(iOS 14.0, macOS 11.0, *) {
      // On iOS 14 and macOS 11, WKWebpagePreferences.allowsContentJavaScript should be
      // used instead.
      throw (pigeonApi.pigeonRegistrar as! ProxyAPIRegistrar)
        .createUnsupportedVersionError(
          method: "WKPreferences.javaScriptEnabled",
          versionRequirements: "< iOS 14.0, macOS 11.0")
    } else {
      pigeonInstance.javaScriptEnabled = enabled
    }
  }

  func setJavaScriptCanOpenWindowsAutomatically(
    pigeonApi: PigeonApiWKPreferences, pigeonInstance: WKPreferences, enabled: Bool
  ) throws {
    pigeonInstance.javaScriptCanOpenWindowsAutomatically = enabled
  }

  func setElementFullscreenEnabled(
    pigeonApi: PigeonApiWKPreferences, pigeonInstance: WKPreferences, enabled: Bool
  ) throws {
    // WebKit ships the HTML Fullscreen API switched off in WKWebView, so a
    // page's own fullscreen control is hidden (YouTube) or inert (Twitch).
    // With it on, macOS WebKit presents the element in its own full-screen
    // window; nothing else is required of the host.
    if #available(iOS 15.4, macOS 12.3, *) {
      pigeonInstance.isElementFullscreenEnabled = enabled
    }
    // Older systems have no public switch; the setting is ignored there.
  }
}

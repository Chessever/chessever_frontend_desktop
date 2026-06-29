#include "flutter_window.h"

#include <optional>

#include "desktop_multi_window/desktop_multi_window_plugin.h"
#include "flutter/generated_plugin_registrant.h"
#include "resource.h"

namespace {

void InstallNativeSystemUpdateMenu(HWND window) {
  HMENU system_menu = GetSystemMenu(window, FALSE);
  if (!system_menu) {
    return;
  }

  AppendMenu(system_menu, MF_SEPARATOR, 0, nullptr);
  AppendMenu(system_menu, MF_STRING, ID_SYSTEM_CHECK_FOR_UPDATES,
             L"Check for Updates...");
}

}  // namespace

FlutterWindow::FlutterWindow(const flutter::DartProject& project)
    : project_(project) {}

FlutterWindow::~FlutterWindow() {}

bool FlutterWindow::OnCreate() {
  if (!Win32Window::OnCreate()) {
    return false;
  }

  InstallNativeSystemUpdateMenu(GetHandle());

  RECT frame = GetClientArea();

  // The size here must match the window dimensions to avoid unnecessary surface
  // creation / destruction in the startup path.
  flutter_controller_ = std::make_unique<flutter::FlutterViewController>(
      frame.right - frame.left, frame.bottom - frame.top, project_);
  // Ensure that basic setup of the controller was successful.
  if (!flutter_controller_->engine() || !flutter_controller_->view()) {
    return false;
  }
  RegisterPlugins(flutter_controller_->engine());
  native_update_menu_channel_ =
      std::make_unique<flutter::MethodChannel<flutter::EncodableValue>>(
          flutter_controller_->engine()->messenger(),
          "chessever.desktop/native_update_menu",
          &flutter::StandardMethodCodec::GetInstance());
  DesktopMultiWindowSetWindowCreatedCallback([](void* controller) {
    auto* flutter_view_controller =
        reinterpret_cast<flutter::FlutterViewController*>(controller);
    RegisterPlugins(flutter_view_controller->engine());
  });
  SetChildContent(flutter_controller_->view()->GetNativeWindow());

  flutter_controller_->engine()->SetNextFrameCallback([&]() {
    this->Show();
  });

  // Flutter can complete the first frame before the "show window" callback is
  // registered. The following call ensures a frame is pending to ensure the
  // window is shown. It is a no-op if the first frame hasn't completed yet.
  flutter_controller_->ForceRedraw();

  return true;
}

void FlutterWindow::OnDestroy() {
  native_update_menu_channel_ = nullptr;

  if (flutter_controller_) {
    flutter_controller_ = nullptr;
  }

  Win32Window::OnDestroy();
}

LRESULT
FlutterWindow::MessageHandler(HWND hwnd, UINT const message,
                              WPARAM const wparam,
                              LPARAM const lparam) noexcept {
  if (message == WM_SYSCOMMAND &&
      (wparam & 0xFFF0) == ID_SYSTEM_CHECK_FOR_UPDATES) {
    if (native_update_menu_channel_) {
      native_update_menu_channel_->InvokeMethod(
          "checkForUpdates", std::make_unique<flutter::EncodableValue>());
    }
    return 0;
  }

  // Give Flutter, including plugins, an opportunity to handle window messages.
  if (flutter_controller_) {
    std::optional<LRESULT> result =
        flutter_controller_->HandleTopLevelWindowProc(hwnd, message, wparam,
                                                      lparam);
    if (result) {
      return *result;
    }
  }

  switch (message) {
    case WM_FONTCHANGE:
      flutter_controller_->engine()->ReloadSystemFonts();
      break;
  }

  return Win32Window::MessageHandler(hwnd, message, wparam, lparam);
}

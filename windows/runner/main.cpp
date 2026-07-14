#include <flutter/dart_project.h>
#include <flutter/flutter_view_controller.h>
#include <windows.h>

#include <utility>
#include <vector>

#include "flutter_window.h"
#include "utils.h"

namespace {

#ifdef CHESSEVER_DEVELOPMENT
constexpr wchar_t kChessEverWindowTitle[] = L"ChessEver Development";
#else
constexpr wchar_t kChessEverWindowTitle[] = L"ChessEver";
#endif

int RunFlutterApplication(std::vector<std::string> command_line_arguments) {
  flutter::DartProject project(L"data");
  project.set_dart_entrypoint_arguments(std::move(command_line_arguments));

  FlutterWindow window(project);
  Win32Window::Point origin(10, 10);
  Win32Window::Size size(1440, 900);
  if (!window.Create(kChessEverWindowTitle, origin, size)) {
    return EXIT_FAILURE;
  }
  window.SetQuitOnClose(true);

  ::MSG msg;
  while (::GetMessage(&msg, nullptr, 0, 0)) {
    ::TranslateMessage(&msg);
    ::DispatchMessage(&msg);
  }

  return EXIT_SUCCESS;
}

}  // namespace

int APIENTRY wWinMain(_In_ HINSTANCE instance, _In_opt_ HINSTANCE prev,
                      _In_ wchar_t *command_line, _In_ int show_command) {
  // Attach to console when present (e.g., 'flutter run') or create a
  // new console when running with a debugger.
  if (!::AttachConsole(ATTACH_PARENT_PROCESS) && ::IsDebuggerPresent()) {
    CreateAndAttachConsole();
  }

  // Initialize COM, so that it is available for use in the library and/or
  // plugins.
  const HRESULT com_result =
      ::CoInitializeEx(nullptr, COINIT_APARTMENTTHREADED);

  const int exit_code = RunFlutterApplication(GetCommandLineArguments());
  if (SUCCEEDED(com_result)) {
    ::CoUninitialize();
  }
  return exit_code;
}

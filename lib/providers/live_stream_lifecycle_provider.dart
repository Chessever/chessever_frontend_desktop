import 'package:flutter/widgets.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';

/// Whether foreground UI live-game streams may hold remote subscriptions.
///
/// The observer lives in Riverpod instead of a widget so a `paused` lifecycle
/// transition tears down dependent streams synchronously. A paused Flutter
/// scheduler is not required to render another frame before the cancellation
/// reaches Supabase. The provider stays alive only while a live stream or
/// bounded event rail is using it.
final liveGameStreamingLifecycleProvider = StateNotifierProvider.autoDispose<
  LiveGameStreamingLifecycleController,
  bool
>((ref) => LiveGameStreamingLifecycleController());

class LiveGameStreamingLifecycleController extends StateNotifier<bool>
    with WidgetsBindingObserver {
  LiveGameStreamingLifecycleController() : this._(_currentWidgetsBinding());

  LiveGameStreamingLifecycleController._(this._binding)
    : super(
        liveGameStreamingAllowedForLifecycleState(_binding?.lifecycleState),
      ) {
    _binding?.addObserver(this);
  }

  final WidgetsBinding? _binding;

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    final allowsStreaming = liveGameStreamingAllowedForLifecycleState(state);
    if (this.state != allowsStreaming) this.state = allowsStreaming;
  }

  @override
  void dispose() {
    _binding?.removeObserver(this);
    super.dispose();
  }
}

WidgetsBinding? _currentWidgetsBinding() {
  try {
    return WidgetsBinding.instance;
  } on FlutterError {
    // Pure ProviderContainer tests can exercise stream disposal without a
    // Flutter binding. Production providers are created after runApp, where
    // the observer is always attached.
    return null;
  }
}

bool liveGameStreamingAllowedForLifecycleState(AppLifecycleState? state) {
  return state == null ||
      state == AppLifecycleState.resumed ||
      state == AppLifecycleState.inactive;
}

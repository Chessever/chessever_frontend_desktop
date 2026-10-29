import 'package:shared_preferences/shared_preferences.dart';

/// Permission is local to this account and this version of the disclosure.
/// A storage failure never grants permission implicitly.
class AiSharingConsent {
  const AiSharingConsent();

  static const instance = AiSharingConsent();
  static String keyFor(String accountId) =>
      'botvinnik_ai_sharing_v1_$accountId';

  Future<bool> isGranted(String accountId) async {
    if (accountId.isEmpty) return false;
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.reload();
      return prefs.getBool(keyFor(accountId)) == true;
    } catch (_) {
      return false;
    }
  }

  Future<void> setGranted(String accountId, bool granted) async {
    if (accountId.isEmpty) throw StateError('Sign in to manage AI sharing.');
    final prefs = await SharedPreferences.getInstance();
    final saved =
        granted
            ? await prefs.setBool(keyFor(accountId), true)
            : await prefs.remove(keyFor(accountId));
    if (!saved) throw StateError('Could not save your AI sharing choice.');
  }
}

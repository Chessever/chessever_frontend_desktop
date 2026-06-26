import 'package:flutter/services.dart';

/// Restricts a text field to a valid ECO code: one letter `A`-`E` optionally
/// followed by up to two digits (e.g. `B`, `B0`, `B03`).
///
/// Filtering happens as the user types, so arbitrary text can never be entered
/// — a leading digit, a sixth letter, or a third digit are all dropped instead
/// of being shown.
class EcoCodeInputFormatter extends TextInputFormatter {
  const EcoCodeInputFormatter();

  @override
  TextEditingValue formatEditUpdate(
    TextEditingValue oldValue,
    TextEditingValue newValue,
  ) {
    final sanitized = sanitizeEcoCode(newValue.text);
    if (sanitized == newValue.text) return newValue;
    return TextEditingValue(
      text: sanitized,
      selection: TextSelection.collapsed(offset: sanitized.length),
    );
  }
}

/// Returns the longest valid ECO-code prefix of [raw]: an `A`-`E` letter
/// followed by at most two digits, upper-cased. Returns `''` when [raw] has no
/// valid leading letter.
String sanitizeEcoCode(String raw) {
  final buffer = StringBuffer();
  for (final rune in raw.toUpperCase().runes) {
    final char = String.fromCharCode(rune);
    if (buffer.isEmpty) {
      if (_isEcoLetter(char)) buffer.write(char);
    } else if (buffer.length < 3 && _isDigit(char)) {
      buffer.write(char);
    }
  }
  return buffer.toString();
}

bool _isEcoLetter(String char) =>
    char.codeUnitAt(0) >= 0x41 && char.codeUnitAt(0) <= 0x45; // A-E

bool _isDigit(String char) =>
    char.codeUnitAt(0) >= 0x30 && char.codeUnitAt(0) <= 0x39; // 0-9

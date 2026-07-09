final RegExp _chesscomEffectDirectiveRegex = RegExp(r'\[%c_effect\s+[^\]]+\]');

/// Removes Chess.com/analysis move-classification directives from PGN
/// comments while preserving any human-written prose in the same comment.
///
/// Example:
/// `{ [%c_effect e4;square;e4;type;Mistake;persistent;true] I blundered }`
/// becomes `{ I blundered }`.
List<String> stripAnalysisEffectDirectivesFromComments(List<String>? comments) {
  if (comments == null || comments.isEmpty) return const <String>[];
  final cleaned = <String>[];
  for (final comment in comments) {
    final next =
        comment
            .replaceAll(_chesscomEffectDirectiveRegex, '')
            .replaceAll(RegExp(r'\s+'), ' ')
            .trim();
    if (next.isNotEmpty) cleaned.add(next);
  }
  return List<String>.unmodifiable(cleaned);
}

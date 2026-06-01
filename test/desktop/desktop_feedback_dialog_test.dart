import 'package:flutter_test/flutter_test.dart';

import 'package:chessever/desktop/widgets/desktop_feedback_dialog.dart';

void main() {
  test('desktop feedback metadata marks screenshot inclusion', () {
    expect(
      desktopFeedbackMessageWithMetadata(
        message: '  Board freezes after paste  ',
        screenshotIncluded: true,
      ),
      contains('Feedback: Board freezes after paste'),
    );
    expect(
      desktopFeedbackMessageWithMetadata(
        message: 'Board freezes after paste',
        screenshotIncluded: true,
      ),
      contains('Screenshot: included'),
    );
  });
}

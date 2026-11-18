import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:forui/forui.dart';
import 'package:chessever/desktop/services/cbh_conversion_service.dart';
import 'package:chessever/desktop/widgets/cbh_convert_dialog.dart';

class RecordingConverter extends CbhConversionService {
  int calls = 0;
  @override
  Future<String?> convert(
    String source, {
    void Function(String)? onProgress,
  }) async {
    calls++;
    return 'converted.pgn';
  }
}

class ChoiceConverter extends RecordingConverter {
  @override
  Future<String?> convert(
    String source, {
    void Function(String)? onProgress,
  }) async {
    calls++;
    if (existingCopyChoice == 'ask') {
      existingCopyPath = 'renamed.pgn';
      existingCopyEdited = true;
      return null;
    }
    existingCopyPath = null;
    return 'renamed.pgn';
  }
}

class FailingConverter extends RecordingConverter {
  @override
  Future<String?> convert(
    String source, {
    void Function(String)? onProgress,
  }) async {
    throw const CbhConversionException('Missing companion files.');
  }
}

class PreservationConverter extends RecordingConverter {
  @override
  String? get preservationSummary =>
      '197 records contain ChessBase fields retained as raw metadata, not displayed.';
}

void main() {
  testWidgets('the file list and Cancel remain reachable in a small viewport', (
    tester,
  ) async {
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = const Size(320, 280);
    addTearDown(tester.view.resetDevicePixelRatio);
    addTearDown(tester.view.resetPhysicalSize);
    await tester.pumpWidget(
      MaterialApp(
        home: Builder(
          builder:
              (context) => Center(
                child: GestureDetector(
                  onTap: () => showCbhConvertDialog(context, 'example.cbh'),
                  child: const Text('Open database'),
                ),
              ),
        ),
      ),
    );
    await tester.tap(find.text('Open database'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Details'));
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
    expect(find.textContaining('.cbg, and .cba'), findsOneWidget);
    await tester.ensureVisible(find.text('Cancel'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Cancel'));
    await tester.pumpAndSettle();
    expect(find.text('Open ChessBase database?'), findsNothing);
  });

  testWidgets('conversion errors stay visible outside Details', (tester) async {
    await tester.pumpWidget(
      MaterialApp(
        home: FTheme(
          data: FThemes.zinc.dark,
          child: CbhConvertDialog(
            source: 'example.cbh',
            service: FailingConverter(),
          ),
        ),
      ),
    );
    await tester.tap(find.text('Convert & Open'));
    await tester.pumpAndSettle();
    expect(find.textContaining('Missing companion files.'), findsOneWidget);
    expect(find.text('Conversion complete'), findsNothing);
    expect(find.text('Open PGN'), findsNothing);
    expect(find.text('Details'), findsOneWidget);
    await tester.pump(const Duration(milliseconds: 250));
  });
  for (final choice in ['Open existing copy', 'Create fresh conversion']) {
    testWidgets('edited copy waits for explicit $choice', (tester) async {
      final converter = ChoiceConverter();
      await tester.pumpWidget(
        MaterialApp(
          home: FTheme(
            data: FThemes.zinc.dark,
            child: CbhConvertDialog(source: 'example.cbh', service: converter),
          ),
        ),
      );
      await tester.tap(find.text('Convert & Open'));
      await tester.pumpAndSettle();
      expect(converter.calls, 1);
      expect(find.textContaining('An edited PGN copy exists'), findsOneWidget);
      expect(find.text('Convert & Open'), findsNothing);
      await tester.tap(find.text(choice));
      await tester.pumpAndSettle();
      expect(converter.calls, 2);
      expect(
        converter.existingCopyChoice,
        choice == 'Open existing copy' ? 'reuse' : 'fresh',
      );
      expect(
        converter.selectedCopyPath,
        choice == 'Open existing copy' ? 'renamed.pgn' : null,
      );
    });
  }
  testWidgets('preservation result stays visible until Open PGN', (
    tester,
  ) async {
    final converter = PreservationConverter();
    await tester.pumpWidget(
      MaterialApp(
        home: FTheme(
          data: FThemes.zinc.dark,
          child: CbhConvertDialog(source: 'example.cbh', service: converter),
        ),
      ),
    );
    await tester.tap(find.text('Convert & Open'));
    await tester.pumpAndSettle();
    expect(find.text('Conversion complete'), findsOneWidget);
    expect(find.text('Your PGN copy is ready.'), findsOneWidget);
    expect(find.text(converter.preservationSummary!), findsNothing);
    expect(find.text('Open PGN'), findsOneWidget);
    await tester.tap(find.text('Details'));
    await tester.pumpAndSettle();
    expect(find.text(converter.preservationSummary!), findsOneWidget);
    await tester.tap(find.text('Hide details'));
    await tester.pumpAndSettle();
    expect(find.text(converter.preservationSummary!), findsNothing);
    await tester.pump(const Duration(milliseconds: 250));
    expect(find.text('Convert & Open'), findsNothing);
    expect(converter.calls, 1);
  });
  testWidgets('conversion starts only after explicit Convert & Open consent', (
    tester,
  ) async {
    final converter = RecordingConverter();
    await tester.pumpWidget(
      MaterialApp(
        home: FTheme(
          data: FThemes.zinc.dark,
          child: CbhConvertDialog(source: 'example.cbh', service: converter),
        ),
      ),
    );
    expect(converter.calls, 0);
    expect(find.text('Open ChessBase database?'), findsOneWidget);
    expect(
      find.text(
        'We’ll create a PGN copy and open it. Your original files stay unchanged.',
      ),
      findsOneWidget,
    );
    expect(
      find.textContaining('Select the .cbh index together with its'),
      findsNothing,
    );
    await tester.tap(find.text('Details'));
    await tester.pumpAndSettle();
    expect(
      find.textContaining('Select the .cbh index together with its'),
      findsOneWidget,
    );
    expect(converter.calls, 0);
    expect(
      find.textContaining(
        'Original annotation frames are kept exactly in PGN headers',
      ),
      findsOneWidget,
    );
    expect(find.textContaining('No records are skipped.'), findsOneWidget);
    await tester.tap(find.text('Hide details'));
    await tester.pumpAndSettle();
    expect(
      find.textContaining('Select the .cbh index together with its'),
      findsNothing,
    );
    await tester.tap(find.text('Convert & Open'));
    await tester.pumpAndSettle();
    expect(converter.calls, 1);
  });
}

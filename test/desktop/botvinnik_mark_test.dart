import 'package:chessever/desktop/widgets/botvinnik/botvinnik_mark.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  testWidgets('draws the real brand asset untinted at the requested size', (
    tester,
  ) async {
    await tester.pumpWidget(
      const Directionality(
        textDirection: TextDirection.ltr,
        child: Center(child: BotvinnikMark(size: 30)),
      ),
    );

    final image = tester.widget<Image>(find.byType(Image));
    expect(image.width, 30);
    expect(image.height, 30);
    expect(image.color, isNull, reason: 'the mark keeps its own colours');
    final provider = image.image;
    expect(provider, isA<ResizeImage>());
    final asset = (provider as ResizeImage).imageProvider as AssetImage;
    expect(asset.assetName, BotvinnikMark.asset);
  });
}

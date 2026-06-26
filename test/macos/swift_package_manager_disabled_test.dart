import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:yaml/yaml.dart';

void main() {
  test('macOS release uses CocoaPods-only plugin integration', () {
    final pubspec = loadYaml(
      File('pubspec.yaml').readAsStringSync(),
    ) as YamlMap;
    final project = File('macos/Runner.xcodeproj/project.pbxproj').readAsStringSync();

    expect(
      (pubspec['flutter'] as YamlMap)['config'],
      containsPair('enable-swift-package-manager', false),
      reason:
          'SwiftPM emits malformed PackageProduct.framework bundles for this '
          'project under the current Flutter/Xcode toolchain; release builds '
          'must stay on CocoaPods until that integration is fixed.',
    );
    expect(project, isNot(contains('FlutterGeneratedPluginSwiftPackage')));
    expect(project, isNot(contains('XCLocalSwiftPackageReference')));
    expect(project, isNot(contains('XCSwiftPackageProductDependency')));
  });
}

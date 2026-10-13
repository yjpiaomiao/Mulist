import 'package:mm_native/mm_native.dart';
import 'package:test/test.dart';

void main() {
  test('version', () {
    expect(MmNative.version(), contains('TagLib'));
  });
}

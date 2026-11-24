import 'package:flutter_test/flutter_test.dart';
import 'package:rtm_uv_kalibrasi/main.dart';

void main() {
  testWidgets('RTM UV Controller renders', (WidgetTester tester) async {
    await tester.pumpWidget(const RtmUvApp());
    expect(find.text('RTM UV Controller'), findsOneWidget);
  });
}

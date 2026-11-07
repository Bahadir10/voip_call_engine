import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:voip_call_engine_example/main.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('voip_call_engine example app simulates incoming, answer, and hangup', (
    WidgetTester tester,
  ) async {
    const channel = MethodChannel('dev.flutter.telecom/voip_call_engine');
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (MethodCall call) async {
      if (call.method == 'initializeAndDrainColdStartBuffer') {
        return <Map<String, Object?>>[];
      }
      return null;
    });

    await tester.pumpWidget(const VoipCallEngineExampleApp());
    await tester.pumpAndSettle();

    expect(find.text('voip_call_engine Example'), findsOneWidget);

    await tester.tap(find.text('Simulate Incoming #1'));
    await tester.pumpAndSettle();

    expect(
      find.text('Alice Yılmaz (Line 1) (incomingRinging)'),
      findsOneWidget,
    );

    await tester.tap(find.byTooltip('Answer Call'));
    await tester.pumpAndSettle();

    expect(
      find.text('Alice Yılmaz (Line 1) (connecting)'),
      findsOneWidget,
    );

    await tester.tap(find.byTooltip('Hangup Call'));
    await tester.pumpAndSettle();

    expect(find.text('No active calls.'), findsOneWidget);
  });
}

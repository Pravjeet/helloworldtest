import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:helloworld/main.dart';

/// The startup-error path, which is the only part of [HostelApp] that can be
/// pumped without a live Firebase connection.
///
/// The happy path renders [AuthGate], which immediately subscribes to
/// FirebaseAuth — pumping that in a unit test throws before the first frame.
/// Testing the guard is still worth doing: it is the difference between a
/// misconfigured `firebase_options.dart` showing a readable message and
/// showing a blank white screen, and a blank screen is the single most
/// confusing failure a new install can produce.
void main() {
  testWidgets('a startup failure explains itself instead of going blank', (
    tester,
  ) async {
    await tester.pumpWidget(
      const HostelApp(startupError: 'no internet connection'),
    );

    expect(find.text('Could not connect to Firebase'), findsOneWidget);
    expect(find.byIcon(Icons.cloud_off_rounded), findsOneWidget);

    // The underlying cause is shown, not swallowed — without it the message
    // is useless for actually fixing the problem.
    expect(find.text('no internet connection'), findsOneWidget);
  });

  // There is deliberately no "happy path renders AuthGate" test here.
  // AuthGate reads FirebaseAuth.instance during its very first build, so
  // pumping it without a live Firebase throws [core/no-app] before a frame
  // exists. Testing that would need a mocked firebase_core platform channel,
  // which is a lot of scaffolding to assert one widget appeared.
  // The permission filtering that decides what a signed-in user actually
  // sees is covered by nav_registry_test.dart, with no Firebase involved.
}

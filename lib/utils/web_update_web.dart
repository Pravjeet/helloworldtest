import 'dart:js_interop';
import 'dart:js_interop_unsafe';

/// Reloads the page if a newer build has been deployed since it was opened.
///
/// The check itself lives in web/index.html (`homiReloadIfStale`), which knows
/// exactly which build this page loaded. Missing — e.g. under `flutter run`,
/// which serves its own index — means there is nothing to compare, so this
/// does nothing. Never throws: a failed check must not block signing in.
Future<void> reloadIfNewVersion() async {
  try {
    if (!globalContext.has('homiReloadIfStale')) return;
    await globalContext
        .callMethod<JSPromise<JSAny?>>('homiReloadIfStale'.toJS)
        .toDart;
  } catch (_) {}
}

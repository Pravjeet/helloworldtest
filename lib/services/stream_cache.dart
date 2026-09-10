import 'dart:async';

/// A Firestore snapshot stream that N screens can share for the price of one.
///
/// Firestore bills per document delivered, and `snapshots()` returns a brand
/// new listener every time it is called. With a 2,500-student roster that made
/// the free tier's 50,000 reads/day budget disappear in about nineteen screen
/// opens: six different pages each called `watchUsers`, each one paying for
/// the whole collection, and because the calls sat inside `build()` a filter
/// change or a keystroke could pay for it again.
///
/// This fixes both halves:
///
///   * **One upstream subscription.** Opened on the first listener and held
///     for the rest of the session. The second screen, and the fiftieth,
///     attach to the same live query and cost nothing.
///   * **A stable stream object.** Services hand out the *same* instance for
///     the same query, so `StreamBuilder` sees an unchanged `stream` across
///     rebuilds and never tears down its subscription. That is what stops a
///     keystroke in a search box from re-reading the roster.
///
/// The upstream is deliberately **not** cancelled when the last listener
/// leaves. Navigating away from a page and back is precisely the case worth
/// making free, and dropping the query there would re-read everything on
/// return. The cost of holding it is one live listener, which Firestore only
/// bills for documents that actually change.
///
/// The latest snapshot is replayed to late subscribers, so a page that opens
/// after the data has already arrived renders immediately instead of sitting
/// on a spinner waiting for the next change.
///
/// Because it outlives the widget tree it must be torn down explicitly when
/// the session ends — see [StreamCaches.disposeAll], called on sign-out. Left
/// alive, the next person to log in would inherit the previous user's data
/// and a listener they have no permission to hold.
class CachedStream<T> extends Stream<T> {
  final Stream<T> Function() _open;

  StreamSubscription<T>? _upstream;
  final StreamController<T> _out = StreamController<T>.broadcast();

  T? _latest;
  bool _hasLatest = false;
  Object? _error;
  StackTrace? _trace;

  CachedStream(this._open) {
    StreamCaches._register(this);
  }

  @override
  bool get isBroadcast => true;

  @override
  StreamSubscription<T> listen(
    void Function(T event)? onData, {
    Function? onError,
    void Function()? onDone,
    bool? cancelOnError,
  }) {
    _connect();
    return _replayed().listen(
      onData,
      onError: onError,
      onDone: onDone,
      cancelOnError: cancelOnError,
    );
  }

  /// The cached value (or error) first, then everything that follows.
  ///
  /// `Stream.multi` rather than `async*`, because the order of the two steps
  /// matters and only this one gets it right. The obvious version — yield the
  /// cached value, then `yield*` the controller — reads the cache and
  /// subscribes in separate microtasks, so a snapshot landing in between is
  /// added to a broadcast controller with no listener yet and is dropped
  /// silently. The subscriber keeps the value it replayed and never learns it
  /// went stale.
  ///
  /// Here the subscribe happens first and the replay second, inside one
  /// synchronous callback, so nothing can arrive in the gap and nothing can
  /// arrive out of order. Cancellation is forwarded, so a page that closes
  /// takes its listener with it.
  Stream<T> _replayed() => Stream<T>.multi((controller) {
    final sub = _out.stream.listen(
      controller.add,
      onError: controller.addError,
      onDone: controller.close,
    );
    controller.onCancel = sub.cancel;

    final err = _error;
    if (err != null) {
      controller.addError(err, _trace);
    } else if (_hasLatest) {
      controller.add(_latest as T);
    }
  });

  void _connect() {
    if (_upstream != null || _out.isClosed) return;
    _upstream = _open().listen(
      (value) {
        _latest = value;
        _hasLatest = true;
        _error = null;
        _trace = null;
        if (!_out.isClosed) _out.add(value);
      },
      onError: (Object e, StackTrace st) {
        // Kept so a page opened after a permission error shows the error
        // rather than an eternal spinner.
        _error = e;
        _trace = st;
        _hasLatest = false;
        if (!_out.isClosed) _out.addError(e, st);
      },
    );
  }

  /// Drops the query and forgets the cached snapshot.
  Future<void> dispose() async {
    await _upstream?.cancel();
    _upstream = null;
    _latest = null;
    _hasLatest = false;
    _error = null;
    _trace = null;
    if (!_out.isClosed) await _out.close();
    StreamCaches._forget(this);
  }
}

/// Registry of every live [CachedStream], so sign-out can close all of them
/// without each service having to remember to expose its own reset hook.
///
/// A missed one is not a cosmetic bug: it leaves a Firestore listener open on
/// a collection the next signed-in user may not be allowed to read, which
/// surfaces as a permission error on a screen that never asked for the data.
class StreamCaches {
  StreamCaches._();

  static final Set<CachedStream> _live = {};
  static final Set<CachedStreamPool> _pools = {};

  static void _register(CachedStream s) => _live.add(s);
  static void _forget(CachedStream s) => _live.remove(s);
  static void _registerPool(CachedStreamPool p) => _pools.add(p);

  /// Closes every cached query. Call on sign-out, before the next login.
  static Future<void> disposeAll() async {
    // Copied first — dispose() mutates the set through _forget.
    for (final s in [..._live]) {
      await s.dispose();
    }
    _live.clear();
    // Pools hold references to the streams just closed; without this the next
    // caller is handed a dead stream that will never emit.
    for (final p in _pools) {
      p._byKey.clear();
    }
  }
}

/// A set of [CachedStream]s keyed by their query parameters.
///
/// Most `watch…` methods take an argument — a college id, a fee period — so
/// one cached stream per service is not enough. This keeps one per distinct
/// key and hands back the same instance for repeat calls, which is what makes
/// the stream object stable enough for `StreamBuilder` to leave alone.
class CachedStreamPool<T> {
  final Map<String, CachedStream<T>> _byKey = {};

  CachedStreamPool() {
    StreamCaches._registerPool(this);
  }

  Stream<T> stream(String key, Stream<T> Function() open) =>
      _byKey.putIfAbsent(key, () => CachedStream<T>(open));
}

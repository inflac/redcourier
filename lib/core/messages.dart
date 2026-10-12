/// Base class for errors shown to the user.
///
/// [template] is an English sentence with `{name}` placeholders; it doubles
/// as the translation key. The UI translates it, the core stays free of
/// Flutter and of any language handling.
class AppException implements Exception {
  final String template;
  final Map<String, Object?> args;

  const AppException(this.template, [this.args = const {}]);

  String get message => fillTemplate(template, args);

  @override
  String toString() => message;
}

String fillTemplate(String template, Map<String, Object?> args) {
  var s = template;
  args.forEach((k, v) => s = s.replaceAll('{$k}', '$v'));
  return s;
}

/// The user stopped an upload or download.
class CancelledException extends AppException {
  const CancelledException() : super('Cancelled.');
}

/// Lets the UI stop a running transfer. Running requests register a callback
/// that aborts them (for example by closing their HTTP client).
class CancelToken {
  bool _cancelled = false;
  final _callbacks = <void Function()>{};

  bool get isCancelled => _cancelled;

  void cancel() {
    if (_cancelled) return;
    _cancelled = true;
    for (final cb in List.of(_callbacks)) {
      try {
        cb();
      } catch (_) {}
    }
  }

  void throwIfCancelled() {
    if (_cancelled) throw const CancelledException();
  }

  /// Runs [cb] on cancel. Returns a function that unregisters it.
  void Function() onCancel(void Function() cb) {
    if (_cancelled) {
      cb();
      return () {};
    }
    _callbacks.add(cb);
    return () => _callbacks.remove(cb);
  }
}

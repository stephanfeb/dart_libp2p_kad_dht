/// A context that can be canceled.
/// 
/// This is used to cancel operations that are in progress.
class CancelableContext {
  /// The context string.
  final String context;

  /// Whether the context has been canceled.
  bool _canceled = false;

  /// Creates a new cancelable context.
  CancelableContext(this.context);

  /// Cancels the context.
  void cancel() {
    _canceled = true;
  }

  /// Returns whether the context has been canceled.
  bool get isCanceled => _canceled;
}

/// Creates a new cancelable context.
/// 
/// The context string is passed through to the new context.
CancelableContext createCancelableContext(String ctx) {
  return CancelableContext(ctx);
}

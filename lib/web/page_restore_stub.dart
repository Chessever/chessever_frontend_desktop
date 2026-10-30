/// Native builds never leave the page, so only [timeout] can end the wait.
/// Returns false: the page was not restored from the back-forward cache.
Future<bool> awaitPageRestore(Duration timeout) =>
    Future<bool>.delayed(timeout, () => false);

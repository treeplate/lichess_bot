void foo(final Object? e) {
  (
    user: (e as Map<String, Object?>),
    message: e['text'],
  );
}
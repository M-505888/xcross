import 'package:test/test.dart';
import 'package:xcross/src/flutter/build/ios_plugin_package.dart';

/// Resolving the plugin graph pulls from a dozen GitHub repositories. A reset
/// or refused connection on any one of them used to fail the whole Windows
/// build, even though the same fetch succeeds moments later.
void main() {
  group('transient network failure classification', () {
    test('recognizes the errors seen while resolving SwiftPM dependencies', () {
      const leveldb =
          "fatal: unable to access 'https://github.com/firebase/leveldb.git/': "
          'Recv failure: Connection was reset';
      const promises =
          "fatal: unable to access 'https://github.com/google/promises.git/': "
          'Failed to connect to github.com:443 after 21083 ms: '
          'Could not connect to server';
      const observed = [
        leveldb,
        promises,
        'error: RPC failed; curl 56 GnuTLS recv error',
        'fatal: The remote end hung up unexpectedly',
        'fatal: early EOF',
        'ssh: Could not resolve hostname github.com',
      ];
      for (final error in observed) {
        expect(
          GeneratedPluginsPackage.isTransientNetworkFailure(error),
          isTrue,
          reason: error,
        );
      }
    });

    test('leaves real build failures alone', () {
      const real = [
        "error: no such module 'Flutter'",
        'error: Package.swift:12:3: cannot find type Target in scope',
        'error: the manifest is malformed',
        'Cannot resolve SwiftPM dependencies: product X not found',
      ];
      for (final error in real) {
        expect(
          GeneratedPluginsPackage.isTransientNetworkFailure(error),
          isFalse,
          reason: error,
        );
      }
    });

    test('does not treat our own timeout kill as retryable', () {
      // Retrying would multiply the very stall the timeout exists to cut
      // short, turning a bounded failure back into an unbounded one.
      expect(
        GeneratedPluginsPackage.isTransientNetworkFailure(
          'command timed out after 1800s and was killed: swift package resolve',
        ),
        isFalse,
      );
    });
  });

  group('retryingTransientNetworkFailure', () {
    test('retries a transient failure and then succeeds', () async {
      var attempts = 0;
      final waits = <Duration>[];
      await GeneratedPluginsPackage.retryingTransientNetworkFailure(
        () async {
          attempts++;
          if (attempts < 3) {
            throw Exception('Recv failure: Connection was reset');
          }
        },
        label: 'resolve',
        delay: (duration) async => waits.add(duration),
      );

      expect(attempts, 3);
      // Backoff grows, so a struggling remote is not hammered.
      expect(waits, [const Duration(seconds: 5), const Duration(seconds: 10)]);
    });

    test('gives up after the configured number of attempts', () async {
      var attempts = 0;
      await expectLater(
        GeneratedPluginsPackage.retryingTransientNetworkFailure(
          () {
            attempts++;
            throw Exception('Could not connect to server');
          },
          label: 'resolve',
          delay: (_) async {},
        ),
        throwsA(isA<Exception>()),
      );
      expect(attempts, 3);
    });

    test('fails fast on a real error instead of retrying it', () async {
      var attempts = 0;
      await expectLater(
        GeneratedPluginsPackage.retryingTransientNetworkFailure(
          () {
            attempts++;
            throw Exception("no such module 'Flutter'");
          },
          label: 'resolve',
          delay: (_) async {},
        ),
        throwsA(isA<Exception>()),
      );
      expect(attempts, 1, reason: 'a genuine build error must not be retried');
    });

    test('does not delay when the first attempt works', () async {
      var called = false;
      await GeneratedPluginsPackage.retryingTransientNetworkFailure(
        () async {},
        label: 'resolve',
        delay: (_) async => called = true,
      );
      expect(called, isFalse);
    });
  });
}

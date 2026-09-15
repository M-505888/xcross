import 'dart:io';

import 'package:cli_kit/cli_kit.dart';
import 'package:path/path.dart' as p;
import 'package:xcross/src/compose/build/compose_info_plist.dart';
import 'package:xcross/src/compose/project/kmp_project.dart';
import 'package:xcross/src/errors.dart';

typedef ComposeCopyDirectory =
    Future<void> Function(Directory source, Directory destination);

typedef ComposeMakeExecutable = void Function(String path);

typedef ComposeRenameDirectory =
    Future<Directory> Function(Directory source, String newPath);

abstract final class ComposeAppAssembler {
  static Future<String> assemble({
    required KmpProject project,
    required String runnerPath,
    required String frameworkPath,
  }) => ComposeAppAssembler.withSeams().assemble(
    project: project,
    runnerPath: runnerPath,
    frameworkPath: frameworkPath,
  );

  static ComposeAppAssemblerWithSeams withSeams({
    ComposeCopyDirectory copyDirectory = _copyDirectoryNoSymlinks,
    ComposeMakeExecutable makeExecutable = ProcessRunner.makeExecutable,
    ComposeRenameDirectory renameDirectory = _renameDirectory,
  }) => ComposeAppAssemblerWithSeams(
    copyDirectory: copyDirectory,
    makeExecutable: makeExecutable,
    renameDirectory: renameDirectory,
  );

  static Future<Directory> _renameDirectory(Directory source, String newPath) =>
      source.rename(newPath);

  static Future<void> _copyDirectoryNoSymlinks(
    Directory source,
    Directory destination,
  ) async {
    await destination.create(recursive: true);
    await for (final entity in source.list(followLinks: false)) {
      final target = p.join(destination.path, p.basename(entity.path));
      if (entity is Link) continue;
      if (entity is Directory) {
        await _copyDirectoryNoSymlinks(entity, Directory(target));
      } else if (entity is File) {
        await Directory(p.dirname(target)).create(recursive: true);
        await entity.copy(target);
      }
    }
  }
}

final class ComposeAppAssemblerWithSeams {
  const ComposeAppAssemblerWithSeams({
    required ComposeCopyDirectory copyDirectory,
    required ComposeMakeExecutable makeExecutable,
    required ComposeRenameDirectory renameDirectory,
  }) : _copyDirectory = copyDirectory,
       _makeExecutable = makeExecutable,
       _renameDirectory = renameDirectory;

  final ComposeCopyDirectory _copyDirectory;
  final ComposeMakeExecutable _makeExecutable;
  final ComposeRenameDirectory _renameDirectory;

  Future<String> assemble({
    required KmpProject project,
    required String runnerPath,
    required String frameworkPath,
  }) async {
    final runner = File(runnerPath);
    if (!runner.existsSync()) {
      throw XcrossError('Runner binary not found: $runnerPath');
    }
    final framework = Directory(frameworkPath);
    if (!framework.existsSync()) {
      throw XcrossError('Compose framework not found: $frameworkPath');
    }
    final frameworkBinary = File(p.join(frameworkPath, project.baseName));
    if (!frameworkBinary.existsSync()) {
      throw XcrossError(
        'Compose framework binary not found: ${frameworkBinary.path}',
      );
    }

    final outputDir = p.join(project.root, 'build', 'xcross-ios');
    final outputDirectory = Directory(outputDir);
    final appPath = p.join(outputDir, '${project.appName}.app');
    await outputDirectory.create(recursive: true);

    final stagingContainer = await outputDirectory.createTemp(
      '.${project.appName}.staging.',
    );
    Directory? backupContainer;
    var preserveBackup = false;

    final stagingApp = p.join(stagingContainer.path, '${project.appName}.app');
    String? backupApp;

    try {
      await _buildStagedApp(
        project: project,
        runner: runner,
        framework: framework,
        stagingPath: stagingApp,
      );
      _validateStagedApp(project: project, appPath: stagingApp);

      final finalDir = Directory(appPath);
      if (finalDir.existsSync()) {
        backupContainer = await outputDirectory.createTemp(
          '.${project.appName}.backup.',
        );
        backupApp = p.join(backupContainer.path, '${project.appName}.app');
        await _renameDirectory(finalDir, backupApp);
        preserveBackup = true;
      }

      try {
        await _renameDirectory(Directory(stagingApp), appPath);
      } catch (installError) {
        if (backupApp != null && Directory(backupApp).existsSync()) {
          try {
            await _renameDirectory(Directory(backupApp), appPath);
            preserveBackup = false;
            if (backupContainer!.existsSync()) {
              await backupContainer.delete(recursive: true);
            }
          } catch (restoreError) {
            throw XcrossError(
              'Failed to install staged Compose app at $appPath and failed to restore previous app. '
              'Previous app backup preserved at ${backupContainer!.path}. '
              'Install error: $installError. Restore error: $restoreError',
            );
          }
        }
        rethrow;
      }

      preserveBackup = false;
      if (backupContainer != null && backupContainer.existsSync()) {
        await backupContainer.delete(recursive: true);
      }
      return appPath;
    } finally {
      if (stagingContainer.existsSync()) {
        await stagingContainer.delete(recursive: true);
      }
      if (!preserveBackup &&
          backupContainer != null &&
          backupContainer.existsSync()) {
        await backupContainer.delete(recursive: true);
      }
    }
  }

  Future<void> _buildStagedApp({
    required KmpProject project,
    required File runner,
    required Directory framework,
    required String stagingPath,
  }) async {
    await Directory(p.join(stagingPath, 'Frameworks')).create(recursive: true);

    final runnerDest = p.join(stagingPath, 'Runner');
    await runner.copy(runnerDest);
    await File(
      p.join(stagingPath, 'Info.plist'),
    ).writeAsString(ComposeInfoPlist.build(project: project));
    final frameworkDest = p.join(
      stagingPath,
      'Frameworks',
      '${project.baseName}.framework',
    );
    await _copyDirectory(framework, Directory(frameworkDest));

    await _copyComposeResources(
      project: project,
      frameworkPath: framework.path,
      stagingPath: stagingPath,
    );

    if (!Platform.isWindows) {
      _makeExecutable(runnerDest);
      _makeExecutable(p.join(frameworkDest, project.baseName));
    }
  }

  /// Copies the app's Compose resources in as `compose-resources/`.
  ///
  /// Compose Multiplatform keeps resources *outside* the framework. On iOS the
  /// bundle's `compose-resources/` directory plays the role that `assets/` plays
  /// on Android, so it holds the whole resources root — `compose-resources/
  /// composeResources/<package>/…` — which is what `DefaultIOsResourceReader`
  /// resolves against the main bundle. A bundle assembled without it aborts on the
  /// first composition that touches a resource: a font read from the theme is
  /// enough to raise `MissingResourceException` inside `setContent`, which the
  /// Kotlin runtime turns into `terminateWithUnhandledException` and an
  /// `abort()`. Confirmed on an iPhone: the app launched, composed, and died two
  /// seconds later with a symbolicated `MissingResourceException` for a font.
  Future<void> _copyComposeResources({
    required KmpProject project,
    required String frameworkPath,
    required String stagingPath,
  }) async {
    final source = _composeResourcesRoot(project, frameworkPath);
    if (source == null) return;
    await _copyDirectory(
      source,
      Directory(p.join(stagingPath, 'compose-resources')),
    );
  }

  /// Gradle's aggregated output for the built target — the only one that also
  /// carries resources contributed by dependencies (coil, koin, …). Returns the
  /// resources *root*, whose contents belong in the bundle: it is the directory
  /// holding `composeResources/`, not that directory itself.
  Directory? _composeResourcesRoot(KmpProject project, String frameworkPath) {
    final buildDir = p.join(project.modulePath, 'build');
    final target = _targetFromFrameworkPath(frameworkPath);
    final aggregated = p.join(
      buildDir,
      'kotlin-multiplatform-resources',
      'aggregated-resources',
    );
    final candidates = <String>[
      if (target != null) p.join(aggregated, target),
      if (target != null) p.join(buildDir, 'processedResources', target, 'main'),
      // The framework path does not always name a target (custom layouts, tests),
      // so fall back to whatever Gradle produced, sorted to keep the choice stable.
      ..._resourceCandidates(aggregated, ''),
      ..._resourceCandidates(p.join(buildDir, 'processedResources'), 'main'),
    ];
    for (final candidate in candidates) {
      // A directory is only a resources root if it actually holds
      // `composeResources/`; otherwise a project without resources would get an
      // empty directory in its bundle.
      if (Directory(p.join(candidate, 'composeResources')).existsSync()) {
        return Directory(candidate);
      }
    }
    return null;
  }

  static Iterable<String> _resourceCandidates(String parent, String leaf) {
    final directory = Directory(parent);
    if (!directory.existsSync()) return const [];
    final names =
        directory
            .listSync(followLinks: false)
            .whereType<Directory>()
            .map((entity) => p.basename(entity.path))
            .toList()
          ..sort();
    return names.map((name) => p.join(parent, name, leaf));
  }

  /// `<module>/build/bin/iosArm64/debugFramework/Shared.framework` → `iosArm64`.
  static String? _targetFromFrameworkPath(String frameworkPath) {
    final segments = p.split(frameworkPath);
    final binIndex = segments.indexOf('bin');
    if (binIndex < 0 || binIndex + 1 >= segments.length) return null;
    return segments[binIndex + 1];
  }

  void _validateStagedApp({
    required KmpProject project,
    required String appPath,
  }) {
    final requiredFiles = [
      p.join(appPath, 'Runner'),
      p.join(appPath, 'Info.plist'),
      p.join(
        appPath,
        'Frameworks',
        '${project.baseName}.framework',
        project.baseName,
      ),
    ];
    for (final path in requiredFiles) {
      if (!File(path).existsSync()) {
        throw XcrossError('Staged Compose app is incomplete: missing $path');
      }
    }
  }
}

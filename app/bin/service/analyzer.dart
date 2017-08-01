// Copyright (c) 2017, the Dart project authors.  Please see the AUTHORS file
// for details. All rights reserved. Use of this source code is governed by a
// BSD-style license that can be found in the LICENSE file.

import 'dart:async';
import 'dart:io';
import 'dart:isolate';

import 'package:appengine/appengine.dart';
import 'package:gcloud/db.dart' as db;
import 'package:logging/logging.dart';
import 'package:shelf/shelf_io.dart' as shelf_io;

import 'package:pub_dartlang_org/shared/configuration.dart';
import 'package:pub_dartlang_org/shared/service_utils.dart';
import 'package:pub_dartlang_org/shared/task_client.dart';
import 'package:pub_dartlang_org/shared/task_scheduler.dart';

import 'package:pub_dartlang_org/analyzer/backend.dart';
import 'package:pub_dartlang_org/analyzer/handlers.dart';
import 'package:pub_dartlang_org/analyzer/pana_runner.dart';
import 'package:pub_dartlang_org/analyzer/task_sources.dart';

final Logger logger = new Logger('pub.analyzer');

Future main() async {
  useLoggingPackageAdaptor();

  withAppEngineServices(() async {
    _initFlutterSdk().then((_) async {
      final ReceivePort errorReceivePort = new ReceivePort();

      Future startIsolate() async {
        logger.info('About to start analyzer isolate...');
        final ReceivePort mainReceivePort = new ReceivePort();
        await Isolate.spawn(
          _runScheduler,
          [mainReceivePort.sendPort],
          onError: errorReceivePort.sendPort,
          onExit: errorReceivePort.sendPort,
          errorsAreFatal: true,
        );
        final List<SendPort> sendPorts = await mainReceivePort.take(1).toList();
        registerTaskSendPort(sendPorts[0]);
        logger.info('Analyzer isolate started.');
      }

      errorReceivePort.listen((e) async {
        logger.severe('ERROR from isolate', e);
        // restart isolate after a brief pause
        await new Future.delayed(new Duration(minutes: 1));
        logger.warning('Restarting isolate...');
        await startIsolate();
      });

      for (int i = 0; i < envConfig.isolateCount; i++) {
        await startIsolate();
      }
    });
    return withCorrectDatastore(() async {
      _registerServices();
      await runAppEngine((HttpRequest request) =>
          shelf_io.handleRequest(request, analyzerServiceHandler));
    });
  });
}

void _runScheduler(List<SendPort> sendPorts) {
  useLoggingPackageAdaptor();

  final SendPort mainSendPort = sendPorts[0];
  final ReceivePort taskReceivePort = new ReceivePort();
  mainSendPort.send(taskReceivePort.sendPort);

  withAppEngineServices(() async {
    await withCorrectDatastore(() async {
      _registerServices();
      final PanaRunner runner = new PanaRunner(analysisBackend);
      await new TaskScheduler(runner.runTask, [
        new ManualTriggerTaskSource(taskReceivePort),
        new DatastoreHeadTaskSource(db.dbService),
        new DatastoreHistoryTaskSource(db.dbService),
      ]).run();
    });
  });
}

Future _initFlutterSdk() async {
  if (envConfig.flutterSdkDir == null) {
    logger.warning('FLUTTER_SDK is not set, assuming flutter is in PATH.');
  } else {
    // If the script exists, it is very likely that we are inside the appengine.
    // In local development environment the setup should happen only once, and
    // running the setup script multiple times should be safe (no-op if
    // FLUTTER_SDK directory exists).
    if (FileSystemEntity.isFileSync('/project/app/script/setup-flutter.sh')) {
      logger.warning('Setting up flutter checkout. This may take some time.');
      final ProcessResult result =
          await Process.run('/project/app/script/setup-flutter.sh', []);
      if (result.exitCode != 0) {
        logger.severe(
            'Failed to checkout flutter (exited with ${result.exitCode})\n'
            'stdout: ${result.stdout}\nstderr: ${result.stderr}');
      } else {
        logger.info('Flutter checkout completed.');
      }
    }
  }
}

void _registerServices() {
  registerAnalysisBackend(new AnalysisBackend(db.dbService));
}
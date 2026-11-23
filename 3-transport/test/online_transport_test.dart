// Run with:  dart test   (from 3-transport/)
import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:test/test.dart';
import 'package:transport/transport.dart';

void main() {
  test('healthUri handles http, https, ws, wss, bare hosts and trailing slashes', () {
    expect(OnlineTransport.healthUri('https://x.onrender.com/').toString(), 'https://x.onrender.com/health');
    expect(OnlineTransport.healthUri('http://10.0.0.2:8000').toString(), 'http://10.0.0.2:8000/health');
    expect(OnlineTransport.healthUri('wss://x.example').toString(), 'https://x.example/health');
    expect(OnlineTransport.healthUri('ws://x.example').toString(), 'http://x.example/health');
    expect(OnlineTransport.healthUri(' x.example ').toString(), 'https://x.example/health');
  });

  test('wakeRelay waits until /health says ok', () async {
    var calls = 0;
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    server.listen((req) {
      calls++;
      // A sleeping host answers 502 a couple of times before the app is up.
      if (calls < 3) {
        req.response.statusCode = 502;
      } else {
        req.response.write(jsonEncode({'ok': true}));
      }
      req.response.close();
    });
    await OnlineTransport.wakeRelay('http://127.0.0.1:${server.port}', retryEvery: const Duration(milliseconds: 10));
    expect(calls, 3);
    await server.close(force: true);
  });

  test('wakeRelay gives up after the timeout', () async {
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    server.listen((req) => req.response
      ..statusCode = 503
      ..close());
    await expectLater(
      OnlineTransport.wakeRelay('http://127.0.0.1:${server.port}',
          timeout: const Duration(milliseconds: 200), retryEvery: const Duration(milliseconds: 20)),
      throwsA(isA<TimeoutException>()),
    );
    await server.close(force: true);
  });
}

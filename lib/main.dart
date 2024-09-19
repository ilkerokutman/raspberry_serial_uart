import 'dart:async';
import 'dart:io';

import 'package:dart_periphery/dart_periphery.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_libserialport/flutter_libserialport.dart';
import 'package:window_manager/window_manager.dart';

bool isPi = !kDebugMode;

extension IntToString on int {
  String toHex() => '0x${toRadixString(16)}';
  String toPadded([int width = 3]) => toString().padLeft(width, '0');
  String toTransport() {
    switch (this) {
      case SerialPortTransport.usb:
        return 'USB';
      case SerialPortTransport.bluetooth:
        return 'Bluetooth';
      case SerialPortTransport.native:
        return 'Native';
      default:
        return 'Unknown';
    }
  }
}

String bytesToHex(List<int> bytes) {
  return bytes.map((byte) => byte.toRadixString(16).padLeft(2, '0')).join('');
}

String uint8ListToHex(Uint8List bytes) {
  return bytesToHex(bytes.toList());
}

Uint8List intListToUint8List(List<int> bytes) {
  return Uint8List.fromList(bytes);
}

List<int> uint8ListToIntList(Uint8List bytes) {
  return bytes.toList();
}

List<int> hexStringToBytes(List<String> hexStrings) {
  return hexStrings
      .map((hexString) => int.parse(hexString, radix: 16))
      .toList();
}

List<CommandDef> availableCommands = [
  CommandDef(
    name: 'Test',
    command: [0x3A, 0x01, 0x64, 0x41, 0x42, 0x00, 0x00, 0x0D, 0x0A],
  ),
  CommandDef(
    name: 'Restart',
    command: [0x3A, 0x01, 0x65, 0x00, 0x00, 0x00, 0x00, 0x0D, 0x0A],
  ),
  CommandDef(
    name: 'Single On',
    command: [0x3A, 0x01, 0x68, 0x06, 0x01, 0x00, 0x00, 0x0D, 0x0A],
  ),
  CommandDef(
    name: 'Single Off',
    command: [0x3A, 0x01, 0x68, 0x06, 0x00, 0x00, 0x00, 0x0D, 0x0A],
  ),
];

void main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await windowManager.ensureInitialized();
  WindowOptions windowOptions = WindowOptions(
    size: !isPi ? const Size(800, 480) : null,
    backgroundColor: Colors.black,
    skipTaskbar: false,
    // center: true,
    titleBarStyle: TitleBarStyle.hidden,
    windowButtonVisibility: true,
  );
  windowManager.waitUntilReadyToShow(windowOptions, () async {
    await windowManager.show();
    if (isPi) {
      await windowManager.setFullScreen(true);
    }
    await windowManager.focus();
  });
  runApp(const MainApp());
}

class CommandDef {
  String name;
  List<int> command;
  CommandDef({required this.name, required this.command});
}

class LogDef {
  String data;
  DateTime timestamp;
  LogDef({required this.data, required this.timestamp});
  factory LogDef.add(String data) =>
      LogDef(data: data, timestamp: DateTime.now());
  Widget toWidget() => ListTile(
        dense: true,
        title: Text(data),
        trailing: Text(iso8601ToTimeString(timestamp.toIso8601String())),
      );

  String iso8601ToTimeString(String iso8601Date) {
    DateTime dateTime = DateTime.parse(iso8601Date);
    return dateTime.toString().substring(11, 23);
  }
}

class MainApp extends StatelessWidget {
  const MainApp({super.key});

  @override
  Widget build(BuildContext context) {
    return const MaterialApp(
      home: HomeScreen(),
    );
  }
}

class HomeScreen extends StatefulWidget {
  const HomeScreen({super.key});

  @override
  State<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends State<HomeScreen> {
  late GPIO pin;
  final availablePorts = <dynamic>[];
  SerialPort? selectedPort;
  SerialPortConfig config = SerialPortConfig();
  late SerialPortReader reader;
  final logs = <LogDef>[];
  late StreamSubscription messageSubscription;
  bool txMode = false;
  bool ready = false;
  bool connectionStatus = false;

  @override
  void initState() {
    super.initState();
    if (isPi) {
      initPin();
    }
    discoverPorts();
  }

  @override
  void dispose() {
    messageSubscription.cancel();
    closePort();
    super.dispose();
  }

  void closePort() {
    selectedPort?.close();
    selectedPort?.dispose();
    setState(() => connectionStatus = selectedPort?.isOpen ?? false);
    setState(() => selectedPort = null);
  }

  void initPin() async {
    try {
      pin = GPIO(4, GPIOdirection.gpioDirOut);
      addLog('initialized GPIO pin');
    } on Exception catch (e) {
      addLog('GPIO error:\n${e.toString()}');
    }
    await changeTxMode(false);
  }

  void discoverPorts() {
    setState(() {
      availablePorts.clear();
      availablePorts.addAll(SerialPort.availablePorts);
    });
    addLog('Serial Ports discovered [${availablePorts.length}]');
  }

  void selectPort(port) {
    try {
      setState(() => selectedPort = SerialPort(port));
    } on Exception catch (e) {
      addLog('Failed to select SerialPort($port):\n${e.toString()}');
    }
  }

  void createConfig() {
    try {
      addLog('creating config');
      config.baudRate = 9600;
      config.bits = 8;
      config.parity = SerialPortParity.none;
      config.stopBits = 1;
      config.xonXoff = 0;
      config.rts = 1;
      config.cts = 0;
      config.dsr = 0;
      config.dtr = 1;
      addLog('config created');
    } on Exception catch (e) {
      addLog('createConfig:\n${config.toString()}\n${e.toString()}');
    }
  }

  applyConfig() {
    try {
      setState(() {
        selectedPort!.config = config;
      });
      addLog('config applied');
    } on Exception catch (e) {
      addLog('applyConfig:\n${config.toString()}\n${e.toString()}');
    }
  }

  openPort() {
    try {
      final openResult = selectedPort!.openReadWrite();
      setState(() => connectionStatus = selectedPort!.isOpen);
      addLog('openPort: $openResult');
    } on Exception catch (e) {
      addLog('openPort: ${e.toString()}');
    }
  }

  createListener() {
    try {
      reader = SerialPortReader(selectedPort!, timeout: 2000);
      addLog('created SerialPortReader');
      messageSubscription = reader.stream.listen((data) {
        List<int> result = List.filled(data.length, 0);
        for (int i = 0; i < data.length; i++) {
          result[i] = data[i];
        }
        addLog('receivedData: $result');
      });
      addLog('registered stream listener');
    } on Exception catch (e) {
      addLog('reader: ${e.toString()}');
    }
  }

  void configurePort(port) {
    if (port == null) return;
    selectPort(port);
    if (selectedPort == null) return;
    createConfig();
    openPort();
    applyConfig();
    createListener();
    setState(() => ready = true);
  }

  void sendMessage(List<int> message) async {
    Uint8List bytes = Uint8List.fromList(message);
    addLog('sending message: ${bytesToHex(bytes)}');
    await changeTxMode(true);
    final bytesWritten = selectedPort!.write(bytes);
    addLog('bytesToWrite: ${selectedPort!.bytesToWrite}');
    addLog('bytes written: $bytesWritten');
    await Future.delayed(const Duration(milliseconds: 10));
    addLog('bytesToWrite: ${selectedPort!.bytesToWrite}');
    await changeTxMode(false);
    addLog('Message sent');
  }

  Future<void> changeTxMode(bool value) async {
    if (!isPi) return;
    try {
      pin.write(value);
      await Future.delayed(const Duration(milliseconds: 10));
      setState(() => txMode = value);
      addLog(value ? 'Mode => Transmit' : 'Mode => Receive');
    } on Exception catch (e) {
      addLog('GPIO error:\n${e.toString()}');
    }
  }

  @override
  Widget build(BuildContext context) {
    return selectedPort == null
        ? Scaffold(
            body: ListView.separated(
                itemBuilder: (c, i) => ListTile(
                      title: Text(availablePorts[i]),
                      onTap: () {
                        configurePort(availablePorts[i]);
                      },
                    ),
                separatorBuilder: (context, i) => const Divider(),
                itemCount: availablePorts.length),
          )
        : ready
            ? Scaffold(
                appBar: AppBar(
                  title: Text(
                      '${selectedPort!.description} : ${selectedPort!.name}'),
                  elevation: 2,
                  actions: [
                    TextButton.icon(
                      onPressed: () async => await changeTxMode(!txMode),
                      label: Text(txMode ? 'TX' : 'RX'),
                      icon: txMode
                          ? const Icon(
                              Icons.arrow_upward,
                              color: Colors.green,
                            )
                          : const Icon(
                              Icons.arrow_downward,
                              color: Colors.red,
                            ),
                    ),
                    const SizedBox(width: 16),
                    IconButton(
                      onPressed: () async => await windowManager.minimize(),
                      icon: const Icon(Icons.minimize),
                    ),
                    IconButton(
                      onPressed: () => Process.killPid(pid),
                      icon: const Icon(Icons.close),
                    ),
                    const SizedBox(width: 8),
                  ],
                ),
                body: Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Expanded(
                      flex: 1,
                      child: ListView.separated(
                        itemBuilder: (context, index) => ListTile(
                          title: Text(availableCommands[index].name),
                          onTap: () =>
                              sendMessage(availableCommands[index].command),
                        ),
                        itemCount: availableCommands.length,
                        separatorBuilder: (context, index) =>
                            const Divider(height: 1),
                      ),
                    ),
                    const VerticalDivider(width: 1),
                    Expanded(
                      flex: 3,
                      child: ListView.builder(
                        itemBuilder: (context, index) => logs[index].toWidget(),
                        itemCount: logs.length,
                      ),
                    ),
                  ],
                ),
              )
            : const Scaffold(
                body: Center(
                  child: CircularProgressIndicator(),
                ),
              );
  }

  void addLog(String data) => setState(() => logs.insert(0, LogDef.add(data)));
}

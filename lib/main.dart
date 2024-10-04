import 'dart:async';
import 'dart:io';

import 'package:dart_periphery/dart_periphery.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_libserialport/flutter_libserialport.dart';
import 'package:hee_uart/message_handler.dart';
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

List<int> getCrcBytes(int value) {
  int firstByte = value % 256; // Remainder after dividing by 256
  int secondByte = value ~/ 256; // Integer division by 256
  return [firstByte, secondByte];
}

int serialUartCrc16(Uint8List data) {
  const List<int> crcTable = [
    0x0000,
    0x1021,
    0x2042,
    0x3063,
    0x4084,
    0x50a5,
    0x60c6,
    0x70e7,
    0x8108,
    0x9129,
    0xa14a,
    0xb16b,
    0xc18c,
    0xd1ad,
    0xe1ce,
    0xf1ef
  ];

  int crc = 0xFFFF;

  for (int i = 0; i < data.length; i++) {
    int byte = data[i];
    crc = (crc << 4) ^ crcTable[((crc >> 12) ^ (byte >> 4)) & 0x0F];
    crc = (crc << 4) ^ crcTable[((crc >> 12) ^ (byte & 0x0F)) & 0x0F];
  }

  return crc & 0xFFFF;
}

int startByte = 0x3A;
int stopByte = 0x0D;

String bytesToHex(List<int> bytes) {
  return bytes
      .map((byte) => byte.toRadixString(16).padLeft(2, '0'))
      .join(' ')
      .toUpperCase();
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
  CommandDef(
    name: 'Read Outputs',
    command: [0x3A, 0x01, 0x69, 0x00, 0x00, 0x00, 0x00, 0x0D, 0x0A],
  ),
  CommandDef(
    name: 'Read Inputs',
    command: [0x3A, 0x01, 0x67, 0x00, 0x00, 0x00, 0x00, 0x0D, 0x0A],
  ),
  CommandDef(
    name: 'Read NTC',
    command: [0x3A, 0x01, 0x70, 0x01, 0x00, 0x00, 0x00, 0x0D, 0x0A],
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
  List<int> receivedStack = [];
  List<List<int>> receivedStackCommands = [];
  SerialMessageHandler handler = SerialMessageHandler();
  late TextEditingController input1;
  late TextEditingController input2;
  late TextEditingController input3;
  late TextEditingController input4;
  List<int> textMessage = [];

  @override
  void initState() {
    super.initState();
    input1 = TextEditingController(text: '0')..addListener(onTextChanged);
    input2 = TextEditingController(text: '0')..addListener(onTextChanged);
    input3 = TextEditingController(text: '0')..addListener(onTextChanged);
    input4 = TextEditingController(text: '0')..addListener(onTextChanged);
    if (isPi) {
      initPin();
    }
    discoverPorts();
    handler.onMessage.listen((Uint8List message) {
      // Handle the received message

      List<int> data = intListToUint8List(message);
      int crcInt = serialUartCrc16(
          intListToUint8List([data[1], data[2], data[3], data[4]]));
      List<int> crcBytes = getCrcBytes(crcInt);
      if (crcBytes[0] == data[5] && crcBytes[1] == data[6]) {
        setState(() {
          receivedStackCommands.insert(0, uint8ListToIntList(message));
        });
      } else {
        setState(() {
          receivedStackCommands.insert(0, [
            0x00,
            data[1],
            data[2],
            data[3],
            data[4],
            data[5],
            data[6],
            data[7],
            data[8],
          ]);
        });
      }
    });
  }

  @override
  void dispose() {
    messageSubscription.cancel();
    closePort();
    handler.dispose();
    input1.dispose();
    input2.dispose();
    input3.dispose();
    input4.dispose();
    if (isPi) {
      pin.dispose();
    }
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
        handler.onDataReceived(data);
        /* final messageBuffer = Uint8List(data.length + receivedStack.length);

        // Copy received bytes to the buffer
        for (int i = 0; i < receivedStack.length; i++) {
          messageBuffer[i] = receivedStack[i];
        }

        // Append new data to the buffer
        messageBuffer.setAll(receivedStack.length, data);

        // Reset received stack
        setState(() {
          receivedStack.clear();
        });

        // Extract messages from the buffer
        extractMessages(messageBuffer); */

        // addLog('receivedData: ${messageBuffer.toList()}');

        /*  List<int> result = List.filled(data.length, 0);
        for (int i = 0; i < data.length; i++) {
          result[i] = data[i];
          setState(() {
            receivedStack.add(data[i]);
          });
        }
        addLog('receivedData: $result');

        bool firstDelimiterFound = false;
        int startIndex = 0;

        for (int i = 0; i < receivedStack.length; i++) {
          if (!firstDelimiterFound && receivedStack[i] == 0x3A) {
            firstDelimiterFound = true;
            startIndex = i + 1;
          } else if (firstDelimiterFound && i - startIndex == 8) {
            setState(() {
              receivedStackCommands
                  .add(receivedStack.sublist(startIndex, i + 1));
            });
            startIndex = i + 1;
          }
        }

        // Keep remaining bytes
        setState(() {
          if (startIndex < receivedStack.length) {
            receivedStack = receivedStack.sublist(startIndex);
          } else {
            receivedStack.clear();
          }
        }); */
      });
      addLog('registered stream listener');
    } on Exception catch (e) {
      addLog('reader: ${e.toString()}');
    }
  }

  /* void extractMessages(Uint8List buffer) {
    int messageStart = 0;

    for (int i = 0; i < buffer.length; i++) {
      // Check for start byte
      if (buffer[i] == startByte) {
        messageStart = i;
        break;
      }
    }

    // Check if a message starts within the buffer
    if (messageStart > 0) {
      for (int i = messageStart + 1; i < buffer.length; i++) {
        // Check for stop byte
        if (buffer[i] == stopByte) {
          // Extract the message
          final message = buffer.sublist(messageStart, i + 1);

          // Validate CRC (implementation omitted here)
          // if (isValidCRC(message)) {
          onMessageReceived(message);
          // }

          // Update message start for remaining bytes
          messageStart = i + 1;
        }
      }
    }

    // Keep remaining bytes for the next iteration
    setState(() {
      receivedStack.addAll(buffer.sublist(messageStart));
    });
  } */

  /* void onMessageReceived(Uint8List message) {
    setState(() {
      receivedStackCommands.insert(0, uint8ListToIntList(message));
    });
  } */

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
    List<int> data = [message[1], message[2], message[3], message[4]];
    int crc = serialUartCrc16(intListToUint8List(data));
    List<int> crcBytes = getCrcBytes(crc);
    List<int> messageWithCrc = [
      message[0],
      message[1],
      message[2],
      message[3],
      message[4],
      crcBytes[0],
      crcBytes[1],
      message[7],
      message[8]
    ];

    Uint8List bytes = Uint8List.fromList(messageWithCrc);
    addLog('sending: ${bytesToHex(bytes)}');
    await changeTxMode(true);
    // final bytesWritten =
    selectedPort!.write(bytes);
    // addLog('bytesToWrite: ${selectedPort!.bytesToWrite}');
    // addLog('bytes written: $bytesWritten');
    await Future.delayed(const Duration(milliseconds: 10));
    // addLog('bytesToWrite: ${selectedPort!.bytesToWrite}');
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
                      child: Column(
                        mainAxisSize: MainAxisSize.max,
                        children: [
                          Expanded(
                            child: ListView.separated(
                              itemBuilder: (context, index) => ListTile(
                                title: Text(availableCommands[index].name),
                                onTap: () => sendMessage(
                                    availableCommands[index].command),
                              ),
                              itemCount: availableCommands.length,
                              separatorBuilder: (context, index) =>
                                  const Divider(height: 1),
                            ),
                          ),
                          Divider(),
                          Row(
                            mainAxisAlignment: MainAxisAlignment.spaceBetween,
                            children: [
                              Expanded(
                                  child: TextField(
                                controller: input1,
                                style: TextStyle(fontSize: 10),
                              )),
                              Expanded(
                                  child: TextField(
                                controller: input2,
                                style: TextStyle(fontSize: 10),
                              )),
                              Expanded(
                                  child: TextField(
                                controller: input3,
                                style: TextStyle(fontSize: 10),
                              )),
                              Expanded(
                                  child: TextField(
                                controller: input4,
                                style: TextStyle(fontSize: 10),
                              )),
                              IconButton(
                                icon: Icon(Icons.send),
                                onPressed: () {
                                  //[0x3A, 0x01, 0x64, 0x41, 0x42, 0x00, 0x00, 0x0D, 0x0A]
                                  onTextChanged();
                                  sendMessage(textMessage);
                                },
                              ),
                            ],
                          ),
                          Text('${textMessage.join('-')}'),
                        ],
                      ),
                    ),
                    const VerticalDivider(width: 1),
                    Expanded(
                      flex: 2,
                      child: ListView.builder(
                        itemBuilder: (context, index) => logs[index].toWidget(),
                        itemCount: logs.length,
                      ),
                    ),
                    // VerticalDivider(width: 1),
                    // Expanded(
                    //   flex: 1,
                    //   child: ListView.separated(
                    //     itemBuilder: (context, index) =>
                    //         Text(bytesToHex([receivedStack[index]])),
                    //     itemCount: receivedStack.length,
                    //     separatorBuilder: (context, index) =>
                    //         receivedStack[index] == stopByte ||
                    //                 receivedStack[index] == startByte
                    //             ? Divider()
                    //             : Container(),
                    //   ),
                    // ),
                    const VerticalDivider(width: 1),
                    Expanded(
                      flex: 1,
                      child: ListView.builder(
                        itemBuilder: (context, index) =>
                            Text(bytesToHex(receivedStackCommands[index])),
                        itemCount: receivedStackCommands.length,
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

  void onTextChanged() {
    List<int> message = [
      0x3A,
      int.parse(input1.text),
      int.parse(input2.text),
      int.parse(input3.text),
      int.parse(input4.text),
      0x00,
      0x00,
      0x0D,
      0x0A
    ];
    setState(() {
      textMessage = message;
    });
  }

  void addLog(String data) => setState(() => logs.insert(0, LogDef.add(data)));
}

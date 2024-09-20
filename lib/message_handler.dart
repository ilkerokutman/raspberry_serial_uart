import 'dart:async';
import 'dart:typed_data';

class SerialMessageHandler {
  final List<int> _buffer = [];
  final StreamController<Uint8List> _controller = StreamController<Uint8List>();

  // Expose the stream to allow others to subscribe to the messages
  Stream<Uint8List> get onMessage => _controller.stream;

  // Constants for message structure
  static const int startByte = 0x3A;
  static const int stopByte1 = 0x0D;
  static const int stopByte2 = 0x0A;
  static const int messageLength = 9; // Total length of message [startByte, ..., stopBytes]

  // Function to handle incoming data from stream
  void onDataReceived(Uint8List data) {
    for (var byte in data) {
      _buffer.add(byte);

      // Check if the buffer has the required length for a full message
      if (_buffer.length >= messageLength) {
        // Check for start byte, stop bytes, and overall message structure
        if (_buffer[0] == startByte && 
            _buffer[messageLength - 2] == stopByte1 && 
            _buffer[messageLength - 1] == stopByte2) {
          
          // Extract the message (assuming it fits the format)
          Uint8List message = Uint8List.fromList(_buffer.sublist(0, messageLength));
          
          // Add the message to the stream for subscribers
          _controller.add(message);

          // Clear buffer for next message
          _buffer.clear();
        } else {
          // Remove invalid or incomplete bytes
          _buffer.removeAt(0);
        }
      }
    }
  }

  // Close the StreamController when no longer needed
  void dispose() {
    _controller.close();
  }
}
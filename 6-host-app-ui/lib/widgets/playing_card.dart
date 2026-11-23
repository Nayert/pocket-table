import 'package:flutter/material.dart';

/// Draws a card code like "As" or "Td". "??" draws the back of a card.
class PlayingCard extends StatelessWidget {
  const PlayingCard({super.key, required this.code, this.width = 56});
  final String code;
  final double width;

  static const _suits = {'s': '♠', 'h': '♥', 'd': '♦', 'c': '♣'};

  @override
  Widget build(BuildContext context) {
    final height = width * 1.4;
    final faceDown = code.length != 2 || code == '??';
    final red = !faceDown && (code[1] == 'h' || code[1] == 'd');
    final rank = faceDown ? '' : (code[0] == 'T' ? '10' : code[0]);

    return Container(
      width: width,
      height: height,
      alignment: Alignment.center,
      decoration: BoxDecoration(
        color: faceDown ? const Color(0xFF3E6FE0) : Colors.white,
        borderRadius: BorderRadius.circular(width * 0.14),
        boxShadow: const [BoxShadow(blurRadius: 6, color: Colors.black45, offset: Offset(0, 2))],
      ),
      child: faceDown
          ? null
          : Text(
              '$rank${_suits[code[1]] ?? ''}',
              style: TextStyle(
                fontSize: width * 0.4,
                fontWeight: FontWeight.bold,
                color: red ? const Color(0xFFD31F35) : Colors.black,
              ),
            ),
    );
  }
}

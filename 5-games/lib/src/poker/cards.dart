import 'dart:math';

/// Cards are 2-character strings: rank + suit, e.g. "As", "Td", "9h".
const ranks = '23456789TJQKA';
const suits = 'cdhs';

List<String> newDeck() => [for (final r in ranks.split('')) for (final s in suits.split('')) '$r$s'];

/// Fisher–Yates shuffle. Pass Random.secure() (the platform's ctx.random)
/// so nobody can predict the deck.
List<String> shuffledDeck(Random rng) {
  final deck = newDeck();
  for (var i = deck.length - 1; i > 0; i--) {
    final j = rng.nextInt(i + 1);
    final t = deck[i];
    deck[i] = deck[j];
    deck[j] = t;
  }
  return deck;
}

int rankValue(String card) => ranks.indexOf(card[0]) + 2; // 2..14

const _suitSymbols = {'s': '♠', 'h': '♥', 'd': '♦', 'c': '♣'};

/// "Td" -> "10♦", for text lines on screens.
String prettyCard(String card) {
  final r = card[0] == 'T' ? '10' : card[0];
  return '$r${_suitSymbols[card[1]] ?? card[1]}';
}

String prettyCards(Iterable<String> cards) => cards.map(prettyCard).join(' ');

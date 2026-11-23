import 'cards.dart';

/// Ported from prototype/poker_eval.py (which has the tests that pin it down).
///
/// A score is [category, tiebreak1, tiebreak2, ...]. Compare scores with
/// [compareScores]; higher is better.
const categoryNames = [
  'High card', 'Pair', 'Two pair', 'Three of a kind', 'Straight',
  'Flush', 'Full house', 'Four of a kind', 'Straight flush',
];

int compareScores(List<int> a, List<int> b) {
  for (var i = 0; i < a.length && i < b.length; i++) {
    if (a[i] != b[i]) return a[i].compareTo(b[i]);
  }
  return a.length.compareTo(b.length);
}

String describeScore(List<int> score) => categoryNames[score[0]];

/// Highest card of a straight in these values, or 0 if they aren't one.
int _straightHigh(List<int> values) {
  final v = values.toSet().toList()..sort((a, b) => b.compareTo(a));
  if (v.length != 5) return 0;
  if (v[0] - v[4] == 4) return v[0];
  if (v[0] == 14 && v[1] == 5 && v[2] == 4 && v[3] == 3 && v[4] == 2) return 5; // A-2-3-4-5
  return 0;
}

List<int> evaluate5(List<String> cards) {
  assert(cards.length == 5);
  final values = cards.map(rankValue).toList();
  final flush = cards.map((c) => c[1]).toSet().length == 1;
  final high = _straightHigh(values);

  final counts = <int, int>{};
  for (final v in values) {
    counts[v] = (counts[v] ?? 0) + 1;
  }
  // Sort groups by count, then rank, both descending.
  final groups = counts.entries.toList()
    ..sort((a, b) => a.value != b.value ? b.value.compareTo(a.value) : b.key.compareTo(a.key));
  final shape = groups.map((g) => g.value).join();
  final ordered = groups.map((g) => g.key).toList();
  final desc = [...values]..sort((a, b) => b.compareTo(a));

  if (flush && high > 0) return [8, high];
  if (shape == '41') return [7, ...ordered];
  if (shape == '32') return [6, ...ordered];
  if (flush) return [5, ...desc];
  if (high > 0) return [4, high];
  if (shape == '311') return [3, ...ordered];
  if (shape == '221') return [2, ...ordered];
  if (shape == '2111') return [1, ...ordered];
  return [0, ...desc];
}

/// Best 5-card score from 5 to 7 cards.
List<int> bestHand(List<String> cards) {
  assert(cards.length >= 5 && cards.length <= 7);
  List<int>? best;
  final n = cards.length;
  for (var a = 0; a < n; a++) {
    for (var b = a + 1; b < n; b++) {
      for (var c = b + 1; c < n; c++) {
        for (var d = c + 1; d < n; d++) {
          for (var e = d + 1; e < n; e++) {
            final s = evaluate5([cards[a], cards[b], cards[c], cards[d], cards[e]]);
            if (best == null || compareScores(s, best) > 0) best = s;
          }
        }
      }
    }
  }
  return best!;
}

import 'hand_evaluator.dart';

/// Ported from prototype/pots.py.
class Pot {
  Pot(this.amount, this.eligible);
  int amount;
  final List<String> eligible;
}

/// [contribs]: chips each player put in this hand.
/// [folded]: players who folded (their chips count, but they can't win).
List<Pot> buildPots(Map<String, int> contribs, Set<String> folded) {
  final left = {for (final e in contribs.entries) if (e.value > 0) e.key: e.value};
  final pots = <Pot>[];
  while (left.isNotEmpty) {
    final live = left.keys.where((p) => !folded.contains(p)).toList();
    if (live.isEmpty) {
      final extra = left.values.fold(0, (a, b) => a + b);
      if (pots.isNotEmpty) pots.last.amount += extra;
      break;
    }
    final level = live.map((p) => left[p]!).reduce((a, b) => a < b ? a : b);
    var amount = 0;
    for (final p in left.keys.toList()) {
      final take = left[p]! < level ? left[p]! : level;
      amount += take;
      left[p] = left[p]! - take;
      if (left[p] == 0) left.remove(p);
    }
    pots.add(Pot(amount, live..sort()));
  }
  return pots;
}

/// [scores]: best-hand score for every player still in.
/// [order]: seat order starting left of the dealer; odd chips from a split
/// pot go to the first winner in this order.
Map<String, int> awardPots(List<Pot> pots, Map<String, List<int>> scores, List<String> order) {
  final won = <String, int>{};
  for (final pot in pots) {
    List<int>? best;
    for (final p in pot.eligible) {
      if (best == null || compareScores(scores[p]!, best) > 0) best = scores[p];
    }
    final winners = order.where((p) => pot.eligible.contains(p) && compareScores(scores[p]!, best!) == 0).toList();
    final share = pot.amount ~/ winners.length;
    final rem = pot.amount % winners.length;
    for (var i = 0; i < winners.length; i++) {
      won[winners[i]] = (won[winners[i]] ?? 0) + share + (i < rem ? 1 : 0);
    }
  }
  return won;
}

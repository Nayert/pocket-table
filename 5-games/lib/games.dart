/// All game plugins. To add a game: write a class that implements `Game`
/// from platform_core, export it here and add it to [allGames].
library games;

import 'package:platform_core/platform_core.dart';

import 'src/mafia/mafia_game.dart';
import 'src/poker/poker_game.dart';

export 'src/mafia/mafia_game.dart';
export 'src/poker/poker_game.dart';
export 'src/poker/cards.dart';
export 'src/poker/hand_evaluator.dart';
export 'src/poker/pots.dart';

final List<GameFactory> allGames = [MafiaGame.new, PokerGame.new];

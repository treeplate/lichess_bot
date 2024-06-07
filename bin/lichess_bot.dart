import 'dart:io';

import 'package:lichess_bot/lichess_bot.dart';
import 'package:dartchess/dartchess.dart';

const Map<LichessVariantKey, Rule> variantToRule = {
  LichessVariantKey.standard: Rule.chess,
  LichessVariantKey.chess960: Rule.chess,
  LichessVariantKey.fromPosition: Rule.chess,
  LichessVariantKey.crazyhouse: Rule.crazyhouse,
  LichessVariantKey.antichess: Rule.antichess,
  LichessVariantKey.atomic: Rule.atomic,
  LichessVariantKey.horde: Rule.horde,
  LichessVariantKey.kingOfTheHill: Rule.kingofthehill,
  LichessVariantKey.racingKings: Rule.racingKings,
  LichessVariantKey.threeCheck: Rule.threecheck,
};

void main(List<String> arguments) async {
  String config = File('config.cfg').readAsStringSync();
  List<String> lines = config.split('\n');
  LichessAPIWrapper lichess = LichessAPIWrapper(lines.first);
  lichess.upgradeToBot();
  for (NowPlayingGame game in await lichess.getGamesPlaying()) {
    playGame(lichess, game.gameID);
  }
  lichess.streamUserEvents().listen((e) {
    if (e is LichessChallengeEvent &&
        e.challenge.challenger.name != lines.last) {
      if (e.challenge.rated) {
        lichess.declineChallenge(e.challenge.id, 'casual');
      } else {
        lichess.acceptChallenge(e.challenge.id).then((e2) {
          String gameID = e.challenge.id;
          playGame(lichess, gameID);
        });
      }
    }
  });
}

void playGame(LichessAPIWrapper lichess, String gameID) {
  late LichessColor color;
  late Position chess;
  lichess.streamGameState(gameID).listen((e) {
    try {
      if (e is LichessGameFullEvent) {
        color = e.white.name == 'bushbowl'
            ? LichessColor.white
            : LichessColor.black;
        chess = Position.setupPosition(
            variantToRule[e.variant.key]!,
            e.initialFen == 'startpos'
                ? Setup.standard
                : Setup.parseFen(e.initialFen));
        if (e.state.moves.isNotEmpty) {
          for (String move in e.state.moves.split(' ')) {
            chess = chess.play(Move.fromUci(move)!);
          }
        }
      } else if (e is LichessGameStateEvent) {
        chess = chess.play(Move.fromUci(e.moves.split(' ').last)!);
      } else if (e is LichessChatLineEvent) {
        if (e.room == LichessChatLineRoom.player) {
          lichess.sendChat(gameID, '${e.username}> ${e.text}', false);
        }
      }
      if (!chess.isGameOver &&
          (chess.turn == Side.white) == (color == LichessColor.white)) {
        (Move, bool) move = pickMove(chess);
        lichess.makeMove(gameID, move.$1.uci, move.$2);
      }
    } on FenError catch (e) {
      print(e.message);
    }
  });
}

// returns (move, offeringDraw)
(Move, bool) pickMove(Position position) {
  Iterable<Move> validMoves = position.legalMoves.entries
      .expand((e) => e.value.squares.map((f) => NormalMove(from: e.key, to: f)))
      .followedBy(position.legalDrops.squares.expand((e) {
    if (position.pockets?.value[position.turn] != null) {
      List<Move> moves = [];
      for (Role role in position.pockets!.value[position.turn]!.keys) {
        moves.add(DropMove(to: e, role: role));
      }
    }
    return [];
  }));
  Move bestMove = validMoves.first;
  for (Move move in validMoves) {
    if (compareMoves(position, move, bestMove) > 0) {
      bestMove = move;
    }
  }
  return (bestMove, false);
}

int compareMoves(Position position, Move a, Move b) {
  Side side = position.turn;
  Position aPos = position.play(a);
  Position bPos = position.play(b);
  if (aPos.outcome?.winner == side) {
    return 1;
  }
  if (aPos.outcome?.winner == side.opposite) {
    return -1;
  }
  if (bPos.outcome?.winner == side) {
    return -1;
  }
  if (aPos.outcome?.winner == side.opposite) {
    return 1;
  }
  if (aPos.board.bySide(side.opposite).size <
      bPos.board.bySide(side.opposite).size) {
    return 1;
  }
  if (aPos.board.bySide(side.opposite).size >
      bPos.board.bySide(side.opposite).size) {
    return -1;
  }
  return 0;
}

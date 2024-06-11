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
  // lichess.upgradeToBot();
  for (NowPlayingGame game in await lichess.getGamesPlaying()) {
    playGame(lichess, game.gameID, lines.last);
  }
  lichess.streamUserEvents().listen((e) {
    if (e is LichessChallengeEvent &&
        e.challenge.challenger.name != lines.last) {
      if (e.challenge.rated) {
        lichess.declineChallenge(e.challenge.id, 'casual');
      } else {
        lichess.acceptChallenge(e.challenge.id).then((e2) {
          String gameID = e.challenge.id;
          playGame(lichess, gameID, lines.last);
        });
      }
    }
  });
}

void playGame(LichessAPIWrapper lichess, String gameID, String user) {
  late LichessColor color;
  late Position position;
  lichess.streamGameState(gameID).listen((e) {
    try {
      if (e is LichessGameFullEvent) {
        color = e.white.name == user ? LichessColor.white : LichessColor.black;
        position = Position.setupPosition(
            variantToRule[e.variant.key]!,
            e.initialFen == 'startpos'
                ? Setup.standard
                : Setup.parseFen(e.initialFen));
        if (e.state.moves.isNotEmpty) {
          for (String move in e.state.moves.split(' ')) {
            position = position.play(Move.fromUci(move)!);
          }
        }
      } else if (e is LichessGameStateEvent) {
        position = position.play(Move.fromUci(e.moves.split(' ').last)!);
      } else if (e is LichessChatLineEvent) {
        if (e.text == 'eval') {
          lichess.sendChat(gameID, readableEval(position, 1),
              e.room == LichessChatLineRoom.player);
        } else if (e.text.startsWith('eval ')) {
          try {
            Position newPos = position.play(Move.fromUci(e.text.substring(5))!);
            lichess.sendChat(gameID, readableEval(newPos, 1),
                e.room == LichessChatLineRoom.player);
          } on PlayError catch (err) {
            lichess.sendChat(
                gameID, err.message, e.room == LichessChatLineRoom.player);
          }
        } else if (e.text.startsWith('evald')) {
          try {
            Position newPos = e.text.length > 6 ? position.play(Move.fromUci(e.text.substring(7))!) : position;
            lichess.sendChat(gameID, readableEval(newPos, int.parse(e.text[5])),
                e.room == LichessChatLineRoom.player);
          } on PlayError catch (err) {
            lichess.sendChat(
                gameID, err.message, e.room == LichessChatLineRoom.player);
          } on FormatException catch (err) {
            lichess.sendChat(
                gameID, err.message, e.room == LichessChatLineRoom.player);
          }  on TypeError catch (err) {
            lichess.sendChat(
                gameID, '$err', e.room == LichessChatLineRoom.player);
          }
        } else if (e.text == 'best') {
          lichess.sendChat(gameID, pickMove(position, 1).$1.uci,
              e.room == LichessChatLineRoom.player);
        }
      }
      if (!position.isGameOver &&
          (position.turn == Side.white) == (color == LichessColor.white)) {
        (Move, bool) move = pickMove(position, 1);
        lichess.makeMove(gameID, move.$1.uci, move.$2);
      }
    } on FenError catch (e) {
      print(e.message);
    } on PlayError {
      // three-move repetition is buggy
    } on ApiError catch (e) {
      print(e.message);
    }
  });
}

String readableEval(Position position, int maxDepth) {
  double eval = evaluatePosition(position, maxDepth);
  return '$eval (depth $maxDepth)';
}

// returns (move, offering draw)
(Move, bool) pickMove(Position position, int maxDepth) {
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
    if (compareMoves(position, move, bestMove, maxDepth) < 0) {
      bestMove = move;
    }
  }
  return (bestMove, false);
}

Map<Role, double> pieceTypeScore = {
  Role.bishop: 3,
  Role.king: 0,
  Role.knight: 3,
  Role.pawn: 1,
  Role.queen: 9,
  Role.rook: 5,
};

double evaluatePosition(Position position, int maxDepth) {
  if (position.outcome?.winner == position.turn) {
    return double.infinity;
  }
  if (position.outcome?.winner == position.turn.opposite) {
    return -double.infinity;
  }
  if (position.outcome != null) {
    return 0;
  }
  if (maxDepth > 0) {
    return -evaluatePosition(
        position.play(pickMove(position, maxDepth - 1).$1), maxDepth - 1);
  }
  return position.board.pieces
      .map<double>((e) => e.$2.color == position.turn
          ? pieceTypeScore[e.$2.role]!
          : -pieceTypeScore[e.$2.role]!)
      .reduce((a, b) => a + b);
}

int compareMoves(Position position, Move a, Move b, int maxDepth) {
  Position aPos = position.play(a);
  Position bPos = position.play(b);
  return evaluatePosition(aPos, maxDepth)
      .compareTo(evaluatePosition(bPos, maxDepth));
}

import 'dart:io';

import 'package:lichess_bot/lichess_bot.dart';
import 'package:dartchess/dartchess.dart' hide File;

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
              : Setup.parseFen(e.initialFen),
        );
        if (e.state.moves.isNotEmpty) {
          for (String move in e.state.moves.split(' ')) {
            position = position.play(Move.parse(move)!);
          }
        }
      } else if (e is LichessGameStateEvent) {
        position = position.play(Move.parse(e.moves.split(' ').last)!);
      } else if (e is LichessChatLineEvent) {
        print('message from ${e.username} in ${e.room}: ${e.text}');
        if (e.room == LichessChatLineRoom.player) {
          lichess.sendChat(gameID, '${e.username}: ${e.text}', false);
        }
        if (e.text == 'eval') {
          lichess.sendChat(
            gameID,
            readableEval(position, 1),
            e.room == LichessChatLineRoom.player,
          );
        } else if (e.text.startsWith('eval ')) {
          try {
            Position newPos = position.play(Move.parse(e.text.substring(5))!);
            lichess.sendChat(
              gameID,
              readableEval(newPos, 1),
              e.room == LichessChatLineRoom.player,
            );
          } on PlayException catch (err) {
            lichess.sendChat(
              gameID,
              err.message,
              e.room == LichessChatLineRoom.player,
            );
          }
        } else if (e.text.startsWith('evald')) {
          try {
            Position newPos = e.text.length > 6
                ? position.play(Move.parse(e.text.substring(7))!)
                : position;
            lichess.sendChat(
              gameID,
              readableEval(newPos, int.parse(e.text[5])),
              e.room == LichessChatLineRoom.player,
            );
          } on PlayException catch (err) {
            lichess.sendChat(
              gameID,
              err.message,
              e.room == LichessChatLineRoom.player,
            );
          } on FormatException catch (err) {
            lichess.sendChat(
              gameID,
              err.message,
              e.room == LichessChatLineRoom.player,
            );
          } on TypeError catch (err) {
            lichess.sendChat(
              gameID,
              '$err',
              e.room == LichessChatLineRoom.player,
            );
          }
        } else if (e.text == 'best') {
          lichess.sendChat(
            gameID,
            pickMove(position, 2).$1.uci,
            e.room == LichessChatLineRoom.player,
          );
        } else if (e.text == 'worst') {
          lichess.sendChat(
            gameID,
            pickWorstMove(position, 2).$1.uci,
            e.room == LichessChatLineRoom.player,
          );
        }
      }
      if (!position.isGameOver &&
          (position.turn == Side.white) == (color == LichessColor.white)) {
        (Move, bool) move = pickMove(position, 2);
        print('making move: ${move.$1.uci}');
        lichess.makeMove(gameID, move.$1.uci, move.$2);
      }
    } on FenException catch (e) {
      print(e.cause);
    } on PlayException {
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
      .followedBy(
        position.legalDrops.squares.expand((e) {
          if (position.pockets?.value[position.turn] != null) {
            List<Move> moves = [];
            for (Role role in position.pockets!.value[position.turn]!.keys) {
              moves.add(DropMove(to: e, role: role));
            }
          }
          return [];
        }),
      );
  Move bestMove = validMoves.first;
  for (Move move in validMoves) {
    if (compareMoves(position, bestMove, move, maxDepth) > 0) {
      bestMove = move;
    }
  }
  return (bestMove, false);
}

(Move, bool) pickWorstMove(Position position, int maxDepth) {
  Iterable<Move> validMoves = position.legalMoves.entries
      .expand((e) => e.value.squares.map((f) => NormalMove(from: e.key, to: f)))
      .followedBy(
        position.legalDrops.squares.expand((e) {
          if (position.pockets?.value[position.turn] != null) {
            List<Move> moves = [];
            for (Role role in position.pockets!.value[position.turn]!.keys) {
              moves.add(DropMove(to: e, role: role));
            }
          }
          return [];
        }),
      );
  Move bestMove = validMoves.first;
  for (Move move in validMoves) {
    if (compareMoves(position, bestMove, move, maxDepth) < 0) {
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
      position.play(pickMove(position, maxDepth - 1).$1),
      maxDepth - 1,
    );
  }
  double value =
      position.board.pieces
          .map<double>(
            (e) => e.$2.color == position.turn
                ? pieceTypeScore[e.$2.role]!
                : -pieceTypeScore[e.$2.role]!,
          )
          .reduce((a, b) => a + b) *
      10;
  for ((Square, Piece) piece in position.board.pieces) {
    if (piece.$2.role == Role.pawn) {
      if (piece.$2.color == position.turn) {
        if (position.turn == Side.white) {
          value +=
              (piece.$1.rank.value) / (3.5 - piece.$1.file.value).abs() / 10;
        } else {
          value +=
              (8 - piece.$1.rank.value) /
              (3.5 - piece.$1.file.value).abs() /
              10;
        }
      } else {
        if (piece.$2.color == Side.white) {
          value +=
              -(piece.$1.rank.value) / (3.5 - piece.$1.file.value).abs() / 10;
        } else {
          value +=
              -(8 - piece.$1.rank.value) /
              (3.5 - piece.$1.file.value).abs() /
              10;
        }
      }
      if (position
          .kingAttackers(piece.$1, piece.$2.color.opposite)
          .isNotEmpty) {
        if (piece.$2.color == position.turn) {
          value -= .5;
        } else {
          value += .5;
        }
      }
    }
  }
  return value / 10;
}

/// positive: b>a, negative: a>b
int compareMoves(Position position, Move a, Move b, int maxDepth) {
  Position aPos = position.play(a);
  Position bPos = position.play(b);
  return evaluatePosition(
    aPos,
    maxDepth,
  ).compareTo(evaluatePosition(bPos, maxDepth));
}

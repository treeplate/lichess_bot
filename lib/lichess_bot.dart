// https://lichess.org/api#tag/Bot

import 'dart:async';
import 'dart:convert';
import 'package:ndjson/ndjson.dart';

import 'package:http/http.dart';
import 'package:lichess_client/lichess_client.dart';
export 'package:lichess_client/lichess_client.dart';

typedef TokenDetails = ({String userID, List<String> scopes, DateTime expires});
typedef Opponent = ({String id, int rating, String username});
typedef NowPlayingGame = ({
  String gameID,
  String fullID,
  LichessColor color,
  String fen,
  bool hasMoved,
  bool isMyTurn,
  String lastMove,
  Opponent opponent,
  PerfType perf,
  bool rated,
  Duration? timeRemaining,
  LichessGameEventSource source,
  LichessSpeed speed,
  LichessVariant variant,
});

enum ChallengeRule { noAbort, noRematch, noGiveTime, noClaimWin, noEarlyDraw }

class ApiError {
  final String message;
  @override
  String toString() => 'APIError: $message';
  ApiError(this.message);
}

/// This class attempts to match the API available using https://github.com/lichess-bot-devs/lichess-bot.
class LichessAPIWrapper {
  final String token;

  LichessAPIWrapper(this.token);

  Future<String> _apiGetRequest(String endpoint,
      [final Map<String, List<String>>? queryParams]) {
    var uri = Uri(
        scheme: 'https',
        host: 'lichess.org',
        path: endpoint,
        queryParameters: queryParams);
    var headers = {'Authorization': 'Bearer $token'};
    return get(uri, headers: headers).then((response) {
      if (response.statusCode != 200) {
        Map<String, dynamic> json = jsonDecode(response.body);
        throw ApiError('Error using $endpoint: ${json['error'] ?? response.body}');
      }
      return response.body;
    });
  }

  Future<String> _apiPostRequest(String endpoint, Object? body,
      [final Map<String, List<String>>? queryParams]) {
    var uri = Uri(
      scheme: 'https',
      host: 'lichess.org',
      path: endpoint,
      queryParameters: queryParams,
    );
    var headers = {'Authorization': 'Bearer $token'};
    return post(uri, headers: headers, body: body).then((response) {
      if (response.statusCode != 200) {
        Map<String, dynamic> json = jsonDecode(response.body);
        throw ApiError('Error using $endpoint: ${json['error'] ?? response.body}');
      }
      return response.body;
    });
  }

  void sendChat(String game, String message, bool inPlayerChat) {
    _apiPostRequest(
      'api/bot/game/$game/chat',
      {'text': message, 'room': inPlayerChat ? 'player' : 'spectator'},
    );
  }

  Future<List<LichessGameChatMessage>> getChat(String game) {
    return _apiGetRequest('api/bot/game/$game/chat').then(
      (response) {
        return (jsonDecode(response) as List<Object?>)
            .map<LichessGameChatMessage>((final Object? e) =>
                LichessGameChatMessage.fromJson(e as Map<String, Object?>))
            .toList();
      },
    );
  }

  Future<TokenDetails> getTokenDetails() {
    return _apiPostRequest('api/token/test', token).then(
      (response) {
        Map<String, Object?> rawTokenDetails =
            (jsonDecode(response) as List<Object?>).single
                as Map<String, Object?>;
        return (
          userID: rawTokenDetails['userId'] as String,
          scopes: (rawTokenDetails['scopes'] as String).split(','),
          expires: DateTime.fromMillisecondsSinceEpoch(
              rawTokenDetails['expires'] as int)
        );
      },
    );
  }

  Future<User> getMyProfile() {
    return _apiGetRequest('api/account').then(
      (response) {
        return User.fromJson(jsonDecode(response));
      },
    );
  }

  Future<User> getUserPublicData(String user) {
    return _apiGetRequest('api/user/$user').then(
      (response) {
        return User.fromJson(jsonDecode(response));
      },
    );
  }

  Future<List<NowPlayingGame>> getGamesPlaying() {
    return _apiGetRequest('api/account/playing').then(
      (response) {
        return (jsonDecode(response)['nowPlaying'] as List<Object?>)
            .cast<Map<String, Object?>>()
            .map<NowPlayingGame>(
              (Map<String, Object?> e) => (
                gameID: e['gameId'] as String,
                fullID: e['fullId'] as String,
                color: e['color'] == 'white'
                    ? LichessColor.white
                    : LichessColor.black,
                fen: e['fen'] as String,
                hasMoved: e['hasMoved'] as bool,
                isMyTurn: e['isMyTurn'] as bool,
                lastMove: e['lastMove'] as String,
                opponent: (
                  id: (e['opponent'] as Map<String, Object?>)['id'] as String,
                  rating:
                      (e['opponent'] as Map<String, Object?>)['rating'] as int,
                  username: (e['opponent'] as Map<String, Object?>)['username']
                      as String,
                ),
                perf: PerfType.values.firstWhere((e2) => e2.name == e['perf']),
                rated: e['rated'] as bool,
                timeRemaining: e['secondsLeft'] == null
                    ? null
                    : Duration(seconds: e['secondsLeft'] as int),
                source: LichessGameEventSource.values
                    .firstWhere((e2) => e2.name == e['source']),
                speed: LichessSpeed.values
                    .firstWhere((e2) => e2.name == e['speed']),
                variant: LichessVariant(
                  key: LichessVariantKey.values.firstWhere((e2) =>
                      e2.name == (e['variant'] as Map<String, Object?>)['key']),
                  name: (e['variant'] as Map<String, Object?>)['key'] as String,
                  // this would be a shortened version of the variant name, but i can't find a comprehensive list
                  short: 'XXX',
                ),
              ),
            )
            .toList();
      },
    );
  }

  Stream<NdjsonLine> _apiGetStreamedNDJSON(String endpoint) {
    StreamController<NdjsonLine> controller = StreamController();
    Client()
        .send(Request(
            'GET', Uri(scheme: 'https', host: 'lichess.org', path: endpoint))
          ..headers['Authorization'] = 'Bearer $token')
        .then((response) {
      controller.addStream(response.stream.parseNdjson());
    });
    return controller.stream;
  }

  Stream<LichessBoardGameEvent> streamGameState(String gameID) {
    return _apiGetStreamedNDJSON('/api/bot/game/stream/$gameID').map((e) {
      switch (e.rawJsonValue['type']) {
        case 'opponentGone':
          return LichessOpponentGoneEvent.fromJson(e.rawJsonValue);
        case 'chatLine':
          return LichessChatLineEvent.fromJson(e.rawJsonValue);
        case 'gameState':
          return LichessGameStateEvent.fromJson(e.rawJsonValue);
        case 'gameFull':
          return LichessGameFullEvent.fromJson(e.rawJsonValue);
        default:
          throw FormatException('invalid game event $e');
      }
    });
  }

  Stream<LichessBoardGameIncomingEvent> streamUserEvents() {
    return _apiGetStreamedNDJSON('/api/stream/event').map((e) {
      switch (e.rawJsonValue['type']) {
        case 'gameStart':
          return LichessGameStartEvent.fromJson(e.rawJsonValue);
        case 'gameFinish':
          return LichessGameFinishEvent.fromJson(e.rawJsonValue);
        case 'challenge':
          return LichessChallengeEvent.fromJson(e.rawJsonValue);
        case 'challengeCanceled':
          return LichessChallengeCanceledEvent.fromJson(e.rawJsonValue);
        case 'challengeDeclined':
          return LichessChallengeDeclinedEvent.fromJson(e.rawJsonValue);
        default:
          throw FormatException('invalid game event');
      }
    });
  }

  Future<bool> makeMove(String game, String move, bool offeringDraw) async {
    return jsonDecode(
            await _apiPostRequest('api/bot/game/$game/move/$move', null, {
          'offeringDraw': [offeringDraw.toString()]
        }))['ok'] ==
        true;
  }

  // untested
  void takebackMove(String game, bool takeback) {
    _apiPostRequest(
      'api/bot/game/$game/takeback/$takeback',
      null,
    );
  }

  void abortGame(String game) {
    _apiPostRequest(
      'api/bot/game/$game/abort',
      null,
    );
  }

  void resignFromGame(String game) {
    _apiPostRequest(
      'api/bot/game/$game/resign',
      null,
    );
  }

  Future<void> acceptChallenge(String challenge) {
    return _apiPostRequest(
      'api/challenge/$challenge/accept',
      null,
    );
  }

  /// [declinationReason] must be one of "generic" "later" "tooFast" "tooSlow" "timeControl" "rated" "casual" "standard" "variant" "noBot" "onlyBot" (https://github.com/lichess-org/lila/blob/master/translation/source/challenge.xml)
  void declineChallenge(String challenge, String declinationReason) {
    _apiPostRequest(
      'api/challenge/$challenge/decline',
      null,
    );
  }

  void cancelChallenge(String challenge) {
    _apiPostRequest(
      'api/challenge/$challenge/cancel',
      null,
    );
  }

  Future<String> challengePlayer(
      String opponent, bool rated, LichessGameClock clock, LichessColor? color,
      [LichessVariantKey variant = LichessVariantKey.standard,
      String? initialFen,
      List<ChallengeRule> rules = const []]) {
    return _apiPostRequest(
      'api/challenge/$opponent',
      {
        'rated': rated.toString(),
        if (clock.limit != null) 'clock.limit': clock.limit.toString(),
        if (clock.increment != null)
          'clock.increment': clock.increment.toString(),
        if (clock.daysPerTurn != null) 'days': clock.daysPerTurn.toString(),
        'color': color?.name ?? 'random',
        'variant': variant.name,
        if (initialFen != null) 'fen': initialFen,
        'rules': rules.map((e) => e.name).join(','),
      },
    ).then((response) {
      return jsonDecode(response)['challenge']['id'];
    });
  }

  void upgradeToBot() {
    _apiPostRequest(
      'api/bot/account/upgrade',
      null,
    );
  }
}

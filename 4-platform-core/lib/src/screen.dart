import 'dart:convert';

/// The generic screens the player page knows how to draw.
/// Games describe everything through these, so the page never needs to
/// change when a new game is added.
enum ScreenKind {
  waiting('screen.waiting'),
  private('screen.private'),
  choice('screen.choice'),
  input('screen.input'),
  results('screen.results');

  const ScreenKind(this.messageType);
  final String messageType;
}

/// Extra number entry attached to an option (e.g. "Raise" asks how much).
class OptionInput {
  const OptionInput({required this.min, required this.max, this.step = 1, this.label, this.defaultValue});
  final int min;
  final int max;
  final int step;
  final String? label;
  final int? defaultValue;

  Map<String, dynamic> toJson() => {
        'min': min,
        'max': max,
        'step': step,
        if (label != null) 'label': label,
        if (defaultValue != null) 'default': defaultValue,
      };
}

class Option {
  const Option(this.id, this.label, {this.sub, this.input});
  final String id;
  final String label;
  final String? sub;
  final OptionInput? input;

  Map<String, dynamic> toJson() => {
        'id': id,
        'label': label,
        if (sub != null) 'sub': sub,
        if (input != null) 'input': input!.toJson(),
      };
}

class Screen {
  const Screen._(
    this.kind, {
    this.title,
    this.body,
    this.cards,
    this.lines,
    this.options = const [],
    this.actionId,
    this.min = 1,
    this.max = 1,
    this.inputMin,
    this.inputMax,
    this.textInput = false,
    this.secondsLeft,
    this.submitLabel,
    this.secret = false,
  });

  /// Nothing to do: show a message and a spinner.
  factory Screen.waiting(String message,
          {String? title, List<String>? cards, List<String>? lines, int? secondsLeft, bool secret = false}) =>
      Screen._(ScreenKind.waiting,
          title: title, body: message, cards: cards, lines: lines, secondsLeft: secondsLeft, secret: secret);

  /// Private information (a role, your cards). Can include buttons, e.g. "Ready".
  factory Screen.private({
    required String title,
    String? body,
    List<String>? cards,
    List<String>? lines,
    List<Option> options = const [],
    String? actionId,
    int? secondsLeft,
    bool secret = false,
  }) =>
      Screen._(ScreenKind.private,
          title: title,
          body: body,
          cards: cards,
          lines: lines,
          options: options,
          actionId: actionId,
          secondsLeft: secondsLeft,
          secret: secret);

  /// Pick between [min] and [max] of [options].
  factory Screen.choice({
    required String actionId,
    required List<Option> options,
    String? title,
    String? body,
    List<String>? cards,
    List<String>? lines,
    int min = 1,
    int max = 1,
    int? secondsLeft,
    String? submitLabel,
    bool secret = false,
  }) =>
      Screen._(ScreenKind.choice,
          secret: secret,
          actionId: actionId,
          options: options,
          title: title,
          body: body,
          cards: cards,
          lines: lines,
          min: min,
          max: max,
          secondsLeft: secondsLeft,
          submitLabel: submitLabel);

  /// Type in a number (between [min] and [max]) or, with [text], some text.
  factory Screen.input({
    required String actionId,
    required String title,
    String? body,
    int? min,
    int? max,
    bool text = false,
    int? secondsLeft,
    String? submitLabel,
  }) =>
      Screen._(ScreenKind.input,
          actionId: actionId,
          title: title,
          body: body,
          inputMin: min,
          inputMax: max,
          textInput: text,
          secondsLeft: secondsLeft,
          submitLabel: submitLabel);

  /// End-of-round or end-of-game summary.
  factory Screen.results({
    required String title,
    String? body,
    List<String>? lines,
    List<String>? cards,
    List<Option> options = const [],
    String? actionId,
    int? secondsLeft,
    bool secret = false,
  }) =>
      Screen._(ScreenKind.results,
          title: title,
          body: body,
          lines: lines,
          cards: cards,
          options: options,
          actionId: actionId,
          secondsLeft: secondsLeft,
          secret: secret);

  final ScreenKind kind;
  final String? title;
  final String? body;
  final List<String>? cards;
  final List<String>? lines;
  final List<Option> options;
  final String? actionId;
  final int min;
  final int max;
  final int? inputMin;
  final int? inputMax;
  final bool textInput;
  final int? secondsLeft;
  final String? submitLabel;

  /// Ask the page to hide [body] and [cards] behind "Tap to reveal".
  /// [title] and [lines] stay visible, so never put private info there.
  final bool secret;

  /// Whether the player can send an action from this screen.
  bool get acceptsAction => actionId != null && (options.isNotEmpty || kind == ScreenKind.input);

  Map<String, dynamic> payload({bool includeTimer = true}) => {
        if (title != null) 'title': title,
        if (body != null) 'body': body,
        if (cards != null) 'cards': cards,
        if (lines != null) 'lines': lines,
        if (options.isNotEmpty) 'options': [for (final o in options) o.toJson()],
        if (actionId != null) 'actionId': actionId,
        if (kind == ScreenKind.choice) ...{'min': min, 'max': max},
        if (kind == ScreenKind.input) ...{
          'inputKind': textInput ? 'text' : 'number',
          if (inputMin != null) 'min': inputMin,
          if (inputMax != null) 'max': inputMax,
        },
        if (submitLabel != null) 'submitLabel': submitLabel,
        if (secret) 'secret': true,
        if (includeTimer && secondsLeft != null) 'secondsLeft': secondsLeft,
      };

  Map<String, dynamic> toMessage() => {'type': kind.messageType, 'payload': payload()};

  /// Used to avoid resending a screen that hasn't changed. Ignores the
  /// countdown, which changes every second.
  String get signature => '${kind.messageType}|${jsonEncode(payload(includeTimer: false))}';
}

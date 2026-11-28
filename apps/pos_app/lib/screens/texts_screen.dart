import 'dart:async';
import 'dart:typed_data';

import 'package:flutter/material.dart';

import '../api.dart';
import '../live.dart';
import '../phone.dart' show formatPhoneNumber;
import '../text_pictures.dart';
import '../texts.dart';
import 'theme.dart';

/// What the Texts screen was left with when the customer of a conversation wants food: a to-go order is
/// started for them, with their number and name filled in.
class StartOrderFor {
  const StartOrderFor(this.phone, this.name);

  /// The number as the orders keep it (`7815550142`).
  final String phone;
  final String name;
}

/// The Texts screen was left to book a table for the customer of a conversation, number and name filled in.
class BookTableFor {
  const BookTableFor(this.phone, this.name);

  final String phone;
  final String name;
}

/// Conversations by text with customers (docs/text-inbox.md): what they wrote to the restaurant's number,
/// what somebody here answered, and the POS's own texts to their orders, all by the customer's number.
///
/// A list of the conversations, the one with the newest text first, and the one that is open beside it
/// where there is room; on a phone the list, and the conversation over it. **New text** starts one with a
/// number that has none. From a conversation, **Start order** and **Book a table** leave the screen with a
/// [StartOrderFor] or a [BookTableFor]: the screen underneath takes it from there.
///
/// A text carries pictures too (the button beside the box): from the device's photos or its camera, made to
/// fit a text before they leave the device (`text_pictures.dart`). The hub says whether a picture can go.
///
/// The hub keeps the texts and tells this screen when one came or went. With [only], the screen is one
/// conversation and nothing else: the one an order's **Text** button opens.
class TextsScreen extends StatefulWidget {
  const TextsScreen({
    super.key,
    required this.api,
    required this.staffId,
    this.device = '',
    this.open,
    this.openName = '',
    this.only = false,
    this.nowMs,
    this.pick,
  });

  final PosApi api;

  /// Who is at the screen: the hub writes down who sent a text and who opened a conversation.
  final String staffId;

  /// This device's name, kept with what is sent from it.
  final String device;

  /// The number of the conversation to come up with, however it is written.
  final String? open;

  /// What the screen underneath knows that customer by, for a number the hub has no name for.
  final String openName;

  /// Only the conversation with [open]: no list, and nothing that leads on to an order or a table.
  final bool only;

  /// The hub's clock; the app's reading of it when null.
  final int Function()? nowMs;

  /// How pictures for a text are chosen; the device's own way ([pickPictures]) when null.
  final PicturePick? pick;

  @override
  State<TextsScreen> createState() => _TextsScreenState();
}

class _TextsScreenState extends State<TextsScreen> {
  TextInbox? _inbox;
  String? _open; // the number of the conversation that is open (+17815550142)
  String _openName = ''; // what this screen knows them by, until the hub says
  TextPage? _page; // the open conversation as last read
  String? _problem; // why there is nothing to show: said in the middle of the screen
  bool _away = false; // no hub answers: what shows is what was last read
  bool _sending = false;
  bool _picking = false; // the device's photos are open, or what was chosen is being made to fit
  final _picked = <Uint8List>[]; // the pictures that go with the text in the box
  String? _pickSaid; // what came of choosing pictures, over the box: it must not cover the box as a bar would
  bool _fetching = false; // the texts before the oldest shown are on their way
  int _sent = 0; // counts this screen's texts, for their ids
  final _q = TextEditingController();
  final _draft = TextEditingController();
  final _draftFocus = FocusNode();
  final _pictures = <String, Future<Uint8List?>>{}; // a text's id and the picture's place: its bytes
  Timer? _timer;
  Timer? _typing; // the search waits until the typing stops
  late final _poll = SafetyPoll(widget.api.live);
  late final _reader = Paced(const Duration(milliseconds: 400), _read);
  StreamSubscription<LiveChange>? _live;

  @override
  void initState() {
    super.initState();
    final open = widget.open == null ? null : textNumber(widget.open!);
    _open = open;
    _openName = widget.openName.trim();
    if (widget.only && open == null) _problem = 'This is not a number a text can go to.';
    _timer = Timer.periodic(const Duration(seconds: 2), (_) {
      if (_poll.due()) unawaited(_reader.now(must: false));
    });
    _live = widget.api.live.changes.listen((change) {
      if (change.texts || change.everything) _reader();
    });
    _draft.addListener(_onDraft);
    unawaited(_reader.now());
  }

  @override
  void dispose() {
    _timer?.cancel();
    _typing?.cancel();
    unawaited(_live?.cancel());
    _reader.cancel();
    _q.dispose();
    _draft.dispose();
    _draftFocus.dispose();
    super.dispose();
  }

  DateTime _now() => DateTime.fromMillisecondsSinceEpoch((widget.nowMs ?? widget.api.nowMs)());

  void _onDraft() {
    if (mounted) setState(() {}); // the Send button, the count and what a first text goes as follow the typing
  }

  void _say(String words, {Key? key}) {
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(key: key, content: Text(words)));
  }

  /// The words for a hub that would not answer the texts: who may not read them, a hub older than them.
  static String _refusal(ApiException err) => switch (err.status) {
    403 => 'You may not read the texts here. A manager changes that under Location › Who may do what.',
    404 => 'This hub is older than texts with customers. Update the hub for them.',
    _ => err.detail?['message'] as String? ?? err.message,
  };

  Future<void> _read() async {
    _poll.asked();
    final open = _open;
    try {
      TextInbox? inbox;
      if (!widget.only) inbox = await widget.api.texts(widget.staffId, q: _q.text);
      TextPage? page;
      if (open != null) page = await widget.api.textsWith(widget.staffId, open);
      if (!mounted) return;
      setState(() {
        if (inbox != null) _inbox = inbox;
        // the conversation may have been left, or another opened, while the hub answered
        if (page != null && _open == open) _page = page.keeping(_page);
        _problem = null;
        _away = false;
      });
      if (page != null && _open == open && page.thread.unread > 0) unawaited(_markRead(open!));
    } on ApiException catch (err) {
      if (!mounted) return;
      if (err.status == null) {
        // nothing answers: what was read stays, and it is said that it may be old
        if (_inbox == null && _page == null) {
          setState(() => _problem = 'The hub cannot be reached, and the texts are kept there.');
        } else if (!_away) {
          setState(() => _away = true);
        }
      } else {
        setState(() => _problem = _refusal(err));
      }
    }
  }

  /// Somebody is looking at the conversation: what the customer wrote in it is read, for everybody. The hub
  /// tells every screen, and the dots go.
  Future<void> _markRead(String phone) async {
    try {
      await widget.api.textsRead(widget.staffId, phone);
      if (mounted) _reader(); // the dot goes here at once, told by the hub or not
    } on ApiException {
      // it is read the next time it is looked at
    }
  }

  void _openThread(String phone, {String name = ''}) {
    if (phone == _open) return;
    setState(() {
      _open = phone;
      _openName = name.trim();
      _page = null;
      _draft.clear();
      _picked.clear();
      _pickSaid = null;
    });
    unawaited(_reader.now());
  }

  void _closeThread() {
    setState(() {
      _open = null;
      _page = null;
      _draft.clear();
      _picked.clear();
      _pickSaid = null;
    });
    unawaited(_reader.now());
  }

  void _onSearch(String _) {
    _typing?.cancel();
    _typing = Timer(const Duration(milliseconds: 300), () => unawaited(_reader.now()));
    setState(() {}); // the cross in the box
  }

  /// **New text**: a number is asked for, and its conversation comes up, empty or not.
  Future<void> _new() async {
    final picked = await showDialog<(String, String)>(context: context, builder: (_) => const _NewTextDialog());
    if (picked == null || !mounted) return;
    _openThread(picked.$1, name: picked.$2);
    _draftFocus.requestFocus();
  }

  /// The name the customer goes by on this screen: the hub's, or the one the screen underneath knew.
  String get _name {
    final known = _page?.thread.name.trim() ?? '';
    return known.isNotEmpty ? known : _openName;
  }

  String _id() {
    final device = widget.device.replaceAll(RegExp(r'[^A-Za-z0-9_-]'), '-');
    final short = device.length > 24 ? device.substring(0, 24) : device;
    return '${short.isEmpty ? 'pos' : short}-${DateTime.now().microsecondsSinceEpoch}-${++_sent}';
  }

  /// Why a picture cannot go from this hub yet, for whoever taps the button.
  static const _noPictures =
      'A picture cannot go yet: Twilio has to be able to fetch it from this hub. A manager sets that up '
      'under Location › Keys and connections, Texts to customers.';

  /// The picture button: asks where the pictures come from (a phone has a camera too), lets the person
  /// choose, and keeps what they chose beside the box until the text goes.
  Future<void> _attach() async {
    final sends = _page?.sends ?? const TextSends();
    if (_picking || _sending) return;
    if (!sends.pictures) return setState(() => _pickSaid = _noPictures);
    final room = sends.most - _picked.length;
    if (room <= 0) return setState(() => _pickSaid = 'A text carries ${sends.most} pictures at the most.');
    var from = PictureFrom.library;
    if (takesPhotos) {
      final chosen = await showModalBottomSheet<PictureFrom>(
        context: context,
        showDragHandle: true,
        builder: (context) => SafeArea(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              ListTile(
                key: const ValueKey('text-attach-library'),
                leading: const Icon(Icons.photo_library_outlined),
                title: const Text('Choose from the photos'),
                onTap: () => Navigator.of(context).pop(PictureFrom.library),
              ),
              ListTile(
                key: const ValueKey('text-attach-camera'),
                leading: const Icon(Icons.photo_camera_outlined),
                title: const Text('Take a photo'),
                onTap: () => Navigator.of(context).pop(PictureFrom.camera),
              ),
            ],
          ),
        ),
      );
      if (chosen == null || !mounted) return;
      from = chosen;
    }
    final open = _open;
    setState(() {
      _picking = true;
      _pickSaid = null;
    });
    try {
      final chosen = await (widget.pick ?? pickPictures)(from, room);
      if (!mounted || _open != open) return;
      final good = [for (final picture in chosen) ?picture];
      final bad = chosen.length - good.length;
      setState(() {
        _picked.addAll(good.take(room));
        if (good.length > room) {
          _pickSaid = 'A text carries ${sends.most} pictures at the most: the others were left out.';
        } else if (bad > 0) {
          _pickSaid = bad == 1 && chosen.length == 1
              ? 'That is not a picture a text can carry. A photo, a JPEG or a PNG goes.'
              : '${bad == 1 ? 'One was' : '$bad were'} left out: not a picture a text can carry.';
        }
      });
    } on Object {
      // the device would not open its photos or its camera: it says why itself where it asks leave
      if (mounted && _open == open) setState(() => _pickSaid = 'The pictures could not be opened on this device.');
    } finally {
      if (mounted) setState(() => _picking = false);
    }
  }

  Future<void> _send() async {
    final open = _open;
    final body = _draft.text.trim();
    final pictures = [..._picked];
    if (open == null || (body.isEmpty && pictures.isEmpty) || _sending) return;
    setState(() => _sending = true);
    try {
      final text = await widget.api.sendText(
        widget.staffId,
        open,
        body: body,
        id: _id(),
        name: _name,
        device: widget.device,
        pictures: pictures,
      );
      if (!mounted) return;
      // what was just sent is shown from here, not fetched back from the hub
      for (final (n, picture) in pictures.indexed) {
        _pictures['${text.id}/$n'] = Future.value(picture);
      }
      setState(() {
        _draft.clear();
        _picked.clear();
        _pickSaid = null;
        final page = _page;
        // shown at once, as the hub wrote it down; the reading that follows says the rest
        if (page != null && _open == open && !page.texts.any((had) => had.id == text.id)) {
          _page = page.withTexts([...page.texts, text]);
        }
      });
      unawaited(_reader.now());
    } on ApiException catch (err) {
      if (!mounted) return;
      final kept = pictures.isEmpty ? 'it is still in the box' : 'it is still in the box, with its pictures';
      _say(switch (err.message) {
        _ when err.status == null => 'The hub cannot be reached. The text was not sent: $kept.',
        'stopped' => 'This customer answered STOP: no text goes to them until they text START.',
        'no_service' => 'This hub has no Twilio account yet. A manager types it under Location › Keys and connections.',
        'too_long' => 'That is too long for one text. Send it as two.',
        'no_number' => 'That is not a number a text can go to.',
        'no_way' => _noPictures,
        'too_many' => 'That is more pictures than one text carries. Take one off and send it again.',
        'too_big' => 'Those pictures are too big together for one text. Take one off and send it again.',
        'bad_picture' => 'One of those is not a picture a text can carry. Take it off and send it again.',
        _ => err.detail?['message'] as String? ?? 'The text was not sent (${err.message}).',
      }, key: const ValueKey('text-not-sent'));
      unawaited(_reader.now());
    } finally {
      if (mounted) setState(() => _sending = false);
    }
  }

  /// The texts before the oldest one shown.
  Future<void> _earlier() async {
    final page = _page, open = _open;
    if (page == null || open == null || page.texts.isEmpty || _fetching) return;
    setState(() => _fetching = true);
    try {
      final older = await widget.api.textsWith(widget.staffId, open, beforeMs: page.texts.first.atMs);
      if (!mounted || _open != open) return;
      setState(() => _page = (_page ?? page).withOlder(older));
    } on ApiException {
      if (mounted) _say('The earlier texts could not be read. Try again in a moment.');
    } finally {
      if (mounted) setState(() => _fetching = false);
    }
  }

  Future<Uint8List?> _picture(TextMessage text, TextPicture picture) =>
      _pictures['${text.id}/${picture.n}'] ??= widget.api.textPicture(widget.staffId, text.id, picture.n);

  void _showPicture(Uint8List bytes) {
    unawaited(
      showDialog<void>(
        context: context,
        builder: (context) => Dialog(
          key: const ValueKey('text-picture-large'),
          clipBehavior: Clip.antiAlias,
          child: Stack(
            alignment: Alignment.topRight,
            children: [
              InteractiveViewer(maxScale: 5, child: Image.memory(bytes, fit: BoxFit.contain)),
              IconButton.filledTonal(
                tooltip: 'Close',
                onPressed: () => Navigator.of(context).pop(),
                icon: const Icon(Icons.close),
              ),
            ],
          ),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final width = MediaQuery.sizeOf(context).width;
    final wide = !widget.only && width >= 720;
    final open = _open;
    final inbox = _inbox;
    final conversation = widget.only || (!wide && open != null);
    final from = inbox == null || inbox.number.isEmpty ? '' : formatPhoneNumber(inbox.number);
    final small = theme.textTheme.bodySmall?.copyWith(color: scheme.onSurfaceVariant);
    final problem = _problem;
    final Widget body;
    if (problem != null && (widget.only || inbox == null)) {
      body = _Middle(key: const ValueKey('texts-problem'), icon: Icons.sms_failed_outlined, words: problem);
    } else if (wide) {
      body = Row(
        children: [
          SizedBox(width: 340, child: _list(context)),
          VerticalDivider(width: 1, color: scheme.outlineVariant),
          Expanded(
            child: open == null
                ? const _Middle(
                    key: ValueKey('texts-pick'),
                    icon: Icons.forum_outlined,
                    words: 'Pick a conversation, or start one with New text.',
                  )
                : _conversation(context, header: true),
          ),
        ],
      );
    } else if (conversation) {
      body = _conversation(context, header: false);
    } else {
      body = _list(context);
    }
    return PopScope(
      // on a phone, back from a conversation is the list
      canPop: widget.only || wide || open == null,
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop) _closeThread();
      },
      child: Scaffold(
        appBar: AppBar(
          title: conversation && open != null
              ? _title(context)
              : Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    const Text('Texts'),
                    if (from.isNotEmpty)
                      Text('The restaurant is $from', key: const ValueKey('texts-from'), style: small),
                  ],
                ),
          actions: [
            if (!widget.only && (inbox?.on ?? false))
              IconButton(
                key: const ValueKey('text-new'),
                tooltip: 'New text',
                onPressed: _new,
                icon: const Icon(Icons.add_comment_outlined),
              ),
          ],
        ),
        body: SafeArea(child: body),
      ),
    );
  }

  /// A conversation's name and number, as the title of the screen or, with [pane], the head of its pane.
  Widget _title(BuildContext context, {bool pane = false}) {
    final theme = Theme.of(context);
    final number = formatPhoneNumber(_open);
    final name = _name;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        Text(
          name.isEmpty ? number : name,
          key: const ValueKey('text-thread-title'),
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: pane ? theme.textTheme.titleMedium : null,
        ),
        if (name.isNotEmpty)
          Text(number, style: theme.textTheme.bodySmall?.copyWith(color: theme.colorScheme.onSurfaceVariant)),
      ],
    );
  }

  /// A line across the top that says why texts are not coming, or may be old.
  Widget? _note(BuildContext context) {
    final inbox = _inbox;
    final String words;
    if (_away) {
      words = 'The hub cannot be reached. This is what was last read.';
    } else if (inbox != null && !inbox.on) {
      words =
          'This hub has no Twilio account yet, so no texts come or go. A manager types it under '
          'Location › Keys and connections.';
    } else if (inbox != null && inbox.listening.ok == false) {
      final said = inbox.listening.said.trim();
      words = "Twilio is not answering the hub, so new texts are not showing yet.${said.isEmpty ? '' : ' ($said)'}";
    } else {
      return null;
    }
    final scheme = Theme.of(context).colorScheme;
    return Material(
      key: const ValueKey('texts-note'),
      color: scheme.tertiaryContainer,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Icon(Icons.info_outline, size: 16, color: scheme.onTertiaryContainer),
            const SizedBox(width: 8),
            Expanded(
              child: Text(
                words,
                style: Theme.of(context).textTheme.bodySmall?.copyWith(color: scheme.onTertiaryContainer),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _list(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final inbox = _inbox;
    final threads = inbox?.threads ?? const <TextThread>[];
    final now = _now();
    final finding = _q.text.trim().isNotEmpty;
    return Column(
      children: [
        ?_note(context),
        Padding(
          padding: const EdgeInsets.fromLTRB(12, 8, 12, 4),
          child: TextField(
            key: const ValueKey('texts-find'),
            controller: _q,
            onChanged: _onSearch,
            textInputAction: TextInputAction.search,
            decoration: InputDecoration(
              isDense: true,
              prefixIcon: const Icon(Icons.search, size: 20),
              hintText: 'Find a name, a number or a word',
              suffixIcon: finding
                  ? IconButton(
                      tooltip: 'Clear',
                      icon: const Icon(Icons.close, size: 18),
                      onPressed: () {
                        _q.clear();
                        _onSearch('');
                      },
                    )
                  : null,
            ),
          ),
        ),
        Expanded(
          child: inbox == null
              ? const Center(child: CircularProgressIndicator())
              : threads.isEmpty
              ? _Middle(
                  key: const ValueKey('texts-none'),
                  icon: Icons.sms_outlined,
                  words: finding
                      ? 'No conversation has that in it.'
                      : inbox.on
                      ? 'No texts yet. What a customer texts the restaurant shows here, and New text starts one.'
                      : 'No texts yet.',
                )
              : ListView.separated(
                  key: const ValueKey('texts-list'),
                  itemCount: threads.length,
                  separatorBuilder: (_, _) => Divider(height: 1, indent: 28, color: scheme.outlineVariant),
                  itemBuilder: (context, i) {
                    final thread = threads[i];
                    return _ThreadRow(
                      key: ValueKey('text-thread:${thread.phone}'),
                      thread: thread,
                      now: now,
                      picked: thread.phone == _open,
                      onTap: () => _openThread(thread.phone, name: thread.name),
                    );
                  },
                ),
        ),
      ],
    );
  }

  Widget _conversation(BuildContext context, {required bool header}) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final page = _page;
    final now = _now();
    final texts = page?.texts ?? const <TextMessage>[];
    final thread = page?.thread;
    final onward = !widget.only && thread != null;
    final on = page?.on ?? true;
    final typed = _draft.text.trim();
    final goes = page == null ? typed : wrapped(page, typed, pictures: _picked.isNotEmpty);
    final tooLong = goes.length > textMax;
    final sends = page?.sends ?? const TextSends();
    final nothing = typed.isEmpty && _picked.isEmpty;
    return Column(
      children: [
        if (!header) ?_note(context),
        if (header)
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 10, 16, 0),
            child: Row(children: [Expanded(child: _title(context, pane: true))]),
          ),
        // what Mike asked the texts for: a customer who texts for food or a table gets it without a call
        if (onward)
          Padding(
            padding: const EdgeInsets.fromLTRB(12, 6, 12, 2),
            child: LayoutBuilder(
              builder: (context, box) {
                final order = OutlinedButton.icon(
                  key: const ValueKey('text-start-order'),
                  style: OutlinedButton.styleFrom(visualDensity: VisualDensity.compact),
                  onPressed: () => Navigator.of(context).pop(StartOrderFor(thread.digits, _name)),
                  icon: const Icon(Icons.takeout_dining_outlined, size: 18),
                  label: const Text('Start order', maxLines: 1, overflow: TextOverflow.ellipsis),
                );
                final table = OutlinedButton.icon(
                  key: const ValueKey('text-book-table'),
                  style: OutlinedButton.styleFrom(visualDensity: VisualDensity.compact),
                  onPressed: () => Navigator.of(context).pop(BookTableFor(thread.digits, _name)),
                  icon: const Icon(Icons.event_available_outlined, size: 18),
                  label: const Text('Book a table', maxLines: 1, overflow: TextOverflow.ellipsis),
                );
                // side by side while both fit with their words whole; on a small phone with large type
                // the second goes under the first instead of being cut short
                if (box.maxWidth < MediaQuery.textScalerOf(context).scale(280)) {
                  return Align(
                    alignment: Alignment.centerLeft,
                    child: Wrap(spacing: 8, runSpacing: 4, children: [order, table]),
                  );
                }
                return Row(
                  children: [
                    Expanded(child: order),
                    const SizedBox(width: 8),
                    Expanded(child: table),
                  ],
                );
              },
            ),
          ),
        Expanded(
          child: page == null
              ? const Center(child: CircularProgressIndicator())
              : texts.isEmpty
              ? _Middle(
                  key: const ValueKey('text-thread-empty'),
                  icon: Icons.sms_outlined,
                  words: 'No texts with ${_name.isEmpty ? 'this number' : _name} yet.',
                )
              : LayoutBuilder(
                  builder: (context, box) => ListView.builder(
                    key: const ValueKey('text-thread'),
                    reverse: true, // the newest at the bottom, and it stays there as more come
                    padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                    itemCount: texts.length + (page.more ? 1 : 0),
                    itemBuilder: (context, i) {
                      if (i == texts.length) {
                        return Center(
                          child: TextButton(
                            key: const ValueKey('text-earlier'),
                            onPressed: _fetching ? null : _earlier,
                            child: Text(_fetching ? 'Reading…' : 'Earlier texts'),
                          ),
                        );
                      }
                      final text = texts[texts.length - 1 - i];
                      return _Bubble(
                        key: ValueKey('text:${text.id}'),
                        text: text,
                        now: now,
                        room: box.maxWidth,
                        picture: (picture) => _picture(text, picture),
                        onPicture: _showPicture,
                      );
                    },
                  ),
                ),
        ),
        if (thread != null && thread.stopped)
          _Foot(
            key: const ValueKey('text-stopped'),
            icon: Icons.block,
            words:
                '${_name.isEmpty ? 'This customer' : _name} answered STOP. No text goes to them until they '
                'text START.',
          )
        else if (!on)
          const _Foot(
            key: ValueKey('text-no-service'),
            icon: Icons.info_outline,
            words: 'This hub has no Twilio account yet, so nothing can be sent.',
          )
        else if (page != null) ...[
          if (page.wraps && !nothing)
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 4, 16, 0),
              child: Align(
                alignment: Alignment.centerLeft,
                child: Text(
                  'The first text to a number says who it is from and how to stop them. It goes as:\n$goes',
                  key: const ValueKey('text-goes-as'),
                  maxLines: 5,
                  overflow: TextOverflow.ellipsis,
                  style: theme.textTheme.bodySmall?.copyWith(color: scheme.onSurfaceVariant),
                ),
              ),
            ),
          if (_picked.isNotEmpty)
            SizedBox(
              key: const ValueKey('text-picked'),
              height: 72,
              child: ListView.separated(
                scrollDirection: Axis.horizontal,
                padding: const EdgeInsets.fromLTRB(12, 8, 12, 0),
                itemCount: _picked.length,
                separatorBuilder: (_, _) => const SizedBox(width: 8),
                itemBuilder: (context, i) => _PickedTile(
                  key: ValueKey('text-picked:$i'),
                  n: i,
                  bytes: _picked[i],
                  onOpen: () => _showPicture(_picked[i]),
                  onRemove: _sending
                      ? null
                      : () => setState(() {
                          _picked.removeAt(i);
                          _pickSaid = null;
                        }),
                ),
              ),
            ),
          if (_pickSaid != null)
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 6, 4, 0),
              child: Row(
                key: const ValueKey('text-pick-said'),
                children: [
                  Icon(Icons.info_outline, size: 16, color: scheme.onSurfaceVariant),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(_pickSaid!, style: theme.textTheme.bodySmall?.copyWith(color: scheme.onSurface)),
                  ),
                  IconButton(
                    key: const ValueKey('text-pick-said-off'),
                    tooltip: 'Close',
                    visualDensity: VisualDensity.compact,
                    onPressed: () => setState(() => _pickSaid = null),
                    icon: const Icon(Icons.close, size: 16),
                  ),
                ],
              ),
            ),
          Padding(
            padding: EdgeInsets.fromLTRB(sends.known ? 4 : 12, 6, 8, 8),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.end,
              children: [
                // only where the hub knows of pictures in a text; one that cannot carry them yet says why
                if (sends.known)
                  IconButton(
                    key: const ValueKey('text-attach'),
                    tooltip: 'Add a picture',
                    onPressed: _picking || _sending ? null : _attach,
                    icon: _picking
                        ? const SizedBox(width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 2))
                        : const Icon(Icons.add_photo_alternate_outlined),
                  ),
                Expanded(
                  child: TextField(
                    key: const ValueKey('text-box'),
                    controller: _draft,
                    focusNode: _draftFocus,
                    minLines: 1,
                    maxLines: 5,
                    textCapitalization: TextCapitalization.sentences,
                    decoration: InputDecoration(
                      isDense: true,
                      hintText: _name.isEmpty ? 'Text this customer' : 'Text $_name',
                      // said only near the end: a text is short
                      counterText: goes.length > textMax - 200 ? '${goes.length} / $textMax' : null,
                      errorText: tooLong ? 'Too long for one text' : null,
                    ),
                  ),
                ),
                const SizedBox(width: 4),
                IconButton.filled(
                  key: const ValueKey('text-send'),
                  tooltip: 'Send',
                  onPressed: nothing || tooLong || _sending ? null : _send,
                  icon: _sending
                      ? const SizedBox(width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 2))
                      : const Icon(Icons.send),
                ),
              ],
            ),
          ),
        ],
      ],
    );
  }
}

/// A few words in the middle of an empty place.
class _Middle extends StatelessWidget {
  const _Middle({super.key, required this.icon, required this.words});

  final IconData icon;
  final String words;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(icon, size: 36, color: scheme.outline),
            const SizedBox(height: 12),
            Text(
              words,
              textAlign: TextAlign.center,
              style: theme.textTheme.bodyMedium?.copyWith(color: scheme.onSurfaceVariant),
            ),
          ],
        ),
      ),
    );
  }
}

/// What stands where the box to type in would: why nothing can be sent.
class _Foot extends StatelessWidget {
  const _Foot({super.key, required this.icon, required this.words});

  final IconData icon;
  final String words;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    return Material(
      color: scheme.surfaceContainerHighest,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
        child: Row(
          children: [
            Icon(icon, size: 18, color: scheme.onSurfaceVariant),
            const SizedBox(width: 10),
            Expanded(child: Text(words, style: theme.textTheme.bodyMedium)),
          ],
        ),
      ),
    );
  }
}

/// One conversation's line of the list: who, the newest text, when, and a dot while something in it is
/// not read.
class _ThreadRow extends StatelessWidget {
  const _ThreadRow({super.key, required this.thread, required this.now, required this.picked, required this.onTap});

  final TextThread thread;
  final DateTime now;
  final bool picked;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final last = thread.last;
    final unread = thread.unread > 0;
    final muted = theme.textTheme.bodySmall?.copyWith(color: scheme.onSurfaceVariant);
    return Material(
      color: picked ? scheme.secondaryContainer : Colors.transparent,
      child: InkWell(
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.fromLTRB(8, 8, 12, 8),
          child: Row(
            children: [
              SizedBox(
                width: 20,
                child: unread
                    ? Center(
                        child: Container(
                          key: ValueKey('text-unread:${thread.phone}'),
                          width: 10,
                          height: 10,
                          decoration: BoxDecoration(color: scheme.primary, shape: BoxShape.circle),
                        ),
                      )
                    : null,
              ),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        Expanded(
                          child: Text(
                            thread.title,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: theme.textTheme.titleSmall?.copyWith(
                              fontWeight: unread ? FontWeight.w700 : FontWeight.w500,
                            ),
                          ),
                        ),
                        if (last != null) Text(threadWhen(last.atMs, now), style: muted),
                      ],
                    ),
                    const SizedBox(height: 2),
                    Row(
                      children: [
                        Expanded(
                          child: Text(
                            last == null ? '' : lastWords(last),
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: unread
                                ? theme.textTheme.bodySmall?.copyWith(
                                    color: scheme.onSurface,
                                    fontWeight: FontWeight.w600,
                                  )
                                : muted,
                          ),
                        ),
                        if (thread.stopped)
                          Padding(
                            padding: const EdgeInsets.only(left: 6),
                            child: Text(
                              'STOP',
                              style: muted?.copyWith(color: scheme.error, fontWeight: FontWeight.w700),
                            ),
                          ),
                        if (thread.unread > 1)
                          Padding(
                            padding: const EdgeInsets.only(left: 6),
                            child: Badge(label: Text('${thread.unread}'), backgroundColor: scheme.primary),
                          ),
                      ],
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// One text: the customer's on the left, ours on the right, with its pictures and what became of it.
class _Bubble extends StatelessWidget {
  const _Bubble({
    super.key,
    required this.text,
    required this.now,
    required this.room,
    required this.picture,
    required this.onPicture,
  });

  final TextMessage text;
  final DateTime now;

  /// How wide the conversation is: a text takes most of it and no more.
  final double room;
  final Future<Uint8List?> Function(TextPicture picture) picture;
  final void Function(Uint8List bytes) onPicture;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final ours = !text.inbound;
    final failed = text.failed;
    final fill = failed
        ? scheme.errorContainer
        : ours
        ? scheme.primaryContainer
        : scheme.surfaceContainerHighest;
    final ink = failed
        ? scheme.onErrorContainer
        : ours
        ? scheme.onPrimaryContainer
        : scheme.onSurface;
    final coming = text.picturesN - text.pictures.length;
    final widest = (room * 0.8).clamp(160.0, 520.0);
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 3),
      child: Column(
        crossAxisAlignment: ours ? CrossAxisAlignment.end : CrossAxisAlignment.start,
        children: [
          ConstrainedBox(
            constraints: BoxConstraints(maxWidth: widest),
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
              decoration: BoxDecoration(color: fill, borderRadius: BorderRadius.circular(14)),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: [
                  if (text.pictures.isNotEmpty)
                    Padding(
                      padding: EdgeInsets.only(bottom: text.body.isEmpty ? 0 : 6),
                      child: Wrap(
                        spacing: 6,
                        runSpacing: 6,
                        children: [
                          for (final one in text.pictures)
                            _PictureTile(
                              key: ValueKey('text-picture:${text.id}/${one.n}'),
                              picture: one,
                              bytes: one.image ? picture(one) : null,
                              onOpen: onPicture,
                            ),
                        ],
                      ),
                    ),
                  if (coming > 0)
                    Text(
                      '${picturesWords(coming)} still coming from Twilio',
                      style: theme.textTheme.bodySmall?.copyWith(color: ink),
                    ),
                  if (text.body.isNotEmpty)
                    SelectableText(text.body, style: theme.textTheme.bodyLarge?.copyWith(color: ink)),
                ],
              ),
            ),
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(6, 2, 6, 0),
            child: Text(
              underWords(text, now),
              textAlign: ours ? TextAlign.end : TextAlign.start,
              style: theme.textTheme.labelSmall?.copyWith(color: failed ? scheme.error : scheme.onSurfaceVariant),
            ),
          ),
        ],
      ),
    );
  }
}

/// A picture of a text, small; a tap shows it large. What is no picture is named and not opened.
class _PictureTile extends StatelessWidget {
  const _PictureTile({super.key, required this.picture, required this.bytes, required this.onOpen});

  final TextPicture picture;
  final Future<Uint8List?>? bytes;
  final void Function(Uint8List bytes) onOpen;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    // as tall as its words need: large type makes them three lines and more
    Widget plain(IconData icon, String words) => Container(
      width: 132,
      constraints: const BoxConstraints(minHeight: 132),
      padding: const EdgeInsets.all(8),
      decoration: BoxDecoration(color: scheme.surface, borderRadius: BorderRadius.circular(10)),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Icon(icon, color: scheme.onSurfaceVariant),
          const SizedBox(height: 6),
          Text(words, textAlign: TextAlign.center, style: theme.textTheme.bodySmall),
        ],
      ),
    );
    final bytes = this.bytes;
    if (bytes == null) return plain(Icons.attach_file, 'A file the POS does not show (${picture.type})');
    return FutureBuilder<Uint8List?>(
      future: bytes,
      builder: (context, read) {
        if (read.connectionState != ConnectionState.done) {
          return SizedBox(
            width: 132,
            height: 132,
            child: Center(
              child: SizedBox(
                width: 22,
                height: 22,
                child: CircularProgressIndicator(strokeWidth: 2, color: scheme.onSurfaceVariant),
              ),
            ),
          );
        }
        final data = read.data;
        if (data == null) return plain(Icons.broken_image_outlined, 'The picture could not be fetched');
        return ClipRRect(
          borderRadius: BorderRadius.circular(10),
          child: InkWell(
            onTap: () => onOpen(data),
            child: Image.memory(
              data,
              width: 132,
              height: 132,
              fit: BoxFit.cover,
              gaplessPlayback: true,
              errorBuilder: (_, _, _) => plain(Icons.broken_image_outlined, 'A picture this device cannot show'),
            ),
          ),
        );
      },
    );
  }
}

/// A picture that goes with the text in the box: small, with a cross that takes it off again.
class _PickedTile extends StatelessWidget {
  const _PickedTile({super.key, required this.n, required this.bytes, required this.onOpen, required this.onRemove});

  final int n;
  final Uint8List bytes;
  final VoidCallback onOpen;
  final VoidCallback? onRemove;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return SizedBox(
      width: 64,
      height: 64,
      child: Stack(
        fit: StackFit.expand,
        children: [
          ClipRRect(
            borderRadius: BorderRadius.circular(10),
            child: InkWell(
              onTap: onOpen,
              child: Image.memory(
                bytes,
                fit: BoxFit.cover,
                gaplessPlayback: true,
                cacheWidth: 192,
                errorBuilder: (_, _, _) => ColoredBox(
                  color: scheme.surfaceContainerHighest,
                  child: Icon(Icons.image_outlined, color: scheme.onSurfaceVariant),
                ),
              ),
            ),
          ),
          Align(
            alignment: Alignment.topRight,
            child: Semantics(
              button: true,
              label: 'Take picture ${n + 1} off',
              child: InkWell(
                key: ValueKey('text-picked-off:$n'),
                onTap: onRemove,
                customBorder: const CircleBorder(),
                child: Container(
                  margin: const EdgeInsets.all(3),
                  padding: const EdgeInsets.all(4),
                  decoration: BoxDecoration(color: scheme.inverseSurface, shape: BoxShape.circle),
                  child: Icon(Icons.close, size: 14, color: scheme.onInverseSurface),
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

/// **New text**: the number a conversation is to be opened with, and the name where it is known.
class _NewTextDialog extends StatefulWidget {
  const _NewTextDialog();

  @override
  State<_NewTextDialog> createState() => _NewTextDialogState();
}

class _NewTextDialogState extends State<_NewTextDialog> {
  final _number = TextEditingController();
  final _name = TextEditingController();

  @override
  void dispose() {
    _number.dispose();
    _name.dispose();
    super.dispose();
  }

  void _done() {
    final phone = textNumber(_number.text);
    if (phone != null) Navigator.of(context).pop((phone, _name.text.trim()));
  }

  @override
  Widget build(BuildContext context) {
    final phone = textNumber(_number.text);
    final typed = _number.text.trim().isNotEmpty;
    return AlertDialog(
      title: const Text('New text'),
      content: SizedBox(
        width: 360,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            TextField(
              key: const ValueKey('text-new-number'),
              controller: _number,
              autofocus: true,
              keyboardType: TextInputType.phone,
              onChanged: (_) => setState(() {}),
              onSubmitted: (_) => _done(),
              decoration: InputDecoration(
                labelText: "The customer's mobile number",
                hintText: '781 555 0142',
                errorText: typed && phone == null ? 'Ten digits, like 781 555 0142' : null,
              ),
            ),
            const SizedBox(height: 12),
            TextField(
              key: const ValueKey('text-new-name'),
              controller: _name,
              textCapitalization: TextCapitalization.words,
              onSubmitted: (_) => _done(),
              decoration: const InputDecoration(labelText: 'Their name (if you know it)'),
            ),
          ],
        ),
      ),
      actions: [
        TextButton(onPressed: () => Navigator.of(context).pop(), child: const Text('Cancel')),
        FilledButton(
          key: const ValueKey('text-new-open'),
          onPressed: phone == null ? null : _done,
          child: const Text('Open'),
        ),
      ],
    );
  }
}

/// On a to-go order: the way to the conversation with its customer, and whether they wrote something
/// nobody has read. Plain, like the customer's line.
class TextStrip extends StatelessWidget {
  const TextStrip({super.key, required this.name, required this.thread, required this.onTap});

  /// The customer's name as the order has it.
  final String name;
  final TextThread thread;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final unread = thread.unread > 0;
    final last = thread.last;
    final who = name.trim().isEmpty ? 'the customer' : name.trim();
    final words = unread && last != null
        ? '${thread.unread == 1 ? 'New text' : '${thread.unread} new texts'}: ${lastWords(last)}'
        : thread.stopped
        ? '${who[0].toUpperCase()}${who.substring(1)} answered STOP'
        : last == null
        ? 'Text $who'
        : lastWords(last);
    final style = theme.textTheme.bodySmall?.copyWith(
      color: unread ? scheme.onPrimaryContainer : scheme.onSurface,
      fontWeight: FontWeight.w600,
    );
    final accent = unread ? scheme.onPrimaryContainer : scheme.primary;
    return Material(
      key: const ValueKey('text-strip'),
      color: unread ? scheme.primaryContainer : scheme.surfaceContainerHighest,
      child: InkWell(
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
          child: Row(
            children: [
              Icon(unread ? Icons.mark_chat_unread_outlined : Icons.sms_outlined, size: 16, color: accent),
              const SizedBox(width: 8),
              Expanded(
                child: Text(words, maxLines: 1, overflow: TextOverflow.ellipsis, style: style),
              ),
              Text(unread ? 'Read' : 'Text', style: style?.copyWith(color: accent)),
              Icon(Icons.chevron_right, size: 16, color: accent),
            ],
          ),
        ),
      ),
    );
  }
}

/// Opens the conversation with [phone] over whatever is showing: an order's own Text button.
Future<void> showTextsWith(
  BuildContext context, {
  required PosApi api,
  required String staffId,
  required String phone,
  String name = '',
  String device = '',
}) => Navigator.of(context).push<void>(
  PosPageRoute(
    builder: (_) => TextsScreen(api: api, staffId: staffId, device: device, open: phone, openName: name, only: true),
  ),
);

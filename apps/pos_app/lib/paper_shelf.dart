/// The papers of the print log as a screen has read them so far: each is asked of the hub once (a paper
/// never changes once it is out), a few at a time, the one being looked at before the ones that are not yet.
library;

import 'dart:async';

import 'package:flutter/foundation.dart';

import 'api.dart';
import 'print_log.dart';

/// What the shelf has of one paper: the paper, or why the hub did not give it.
@immutable
class PaperRead {
  const PaperRead.has(PrintPaper this.paper) : problem = null;
  const PaperRead.failed(String this.problem) : paper = null;

  final PrintPaper? paper;
  final String? problem;
}

/// Reads the papers of a log's prints and keeps them. A print that is on the screen asks for its paper with
/// [want] and listens to [of]: only that print is drawn again when its paper comes, not the screen. With
/// every print opened at once the screen names the prints it lists with [ahead], and their papers are read
/// before they are scrolled to, so a print comes onto the screen with its paper already on it.
///
/// No more than [atOnce] are asked for at a time: the one looked at last first, then the ones read ahead in
/// the order of the list. A paper read ahead that the hub did not give is not held against it: it is asked
/// for again when it is looked at, and only then is the failure said.
class PaperShelf {
  PaperShelf(this._read, {required this.problem, this.atOnce = 4});

  final Future<PrintPaper> Function(String job) _read;

  /// Why a paper was not given, in words for the screen.
  final String Function(ApiException err) problem;
  final int atOnce;

  final _slots = <String, ValueNotifier<PaperRead?>>{};
  final _looked = <String, String>{}; // looked at and waiting for a turn, the job by its key: the last goes first
  var _ahead = <String, String>{}; // to be read before they are looked at, in the order of the list
  final _reading = <String>{};
  final _shown = <String>{}; // of the ones being read: the ones looked at, whose failure is said
  final _refused = <String>{}; // read ahead and not given by a hub that answered: not asked ahead again
  bool _closed = false;

  /// A paper is asked for once: what came out does not change. One that went to a fallback printer after
  /// it was first looked at is another paper, since it then carries that printer's line.
  static String keyOf(PrintEntry entry) => '${entry.jobId}|${entry.printedOn}';

  ValueNotifier<PaperRead?> _slot(String key) => _slots.putIfAbsent(key, () => ValueNotifier(null));

  /// What the shelf has of a print's paper: null until the hub answers.
  ValueListenable<PaperRead?> of(PrintEntry entry) => _slot(keyOf(entry));

  /// The print is on the screen: its paper is asked for next, unless it is here or was refused.
  void want(PrintEntry entry) {
    final key = keyOf(entry);
    if (_closed || _slot(key).value != null) return;
    _ahead.remove(key);
    if (_reading.contains(key)) {
      _shown.add(key);
      return;
    }
    _looked
      ..remove(key)
      ..[key] = entry.jobId;
    _next();
  }

  /// The prints whose papers are read before they are looked at, in this order, in place of the ones named
  /// before; none stops the reading ahead.
  void ahead(Iterable<PrintEntry> entries) {
    if (_closed) return;
    final waiting = <String, String>{};
    for (final entry in entries) {
      final key = keyOf(entry);
      if (_slots[key]?.value != null || _reading.contains(key) || _looked.containsKey(key)) continue;
      if (!_refused.contains(key)) waiting[key] = entry.jobId;
    }
    _ahead = waiting;
    _next();
  }

  /// Asks again for a paper the hub did not give.
  void again(PrintEntry entry) {
    final slot = _slot(keyOf(entry));
    if (_closed || slot.value?.paper != null) return;
    slot.value = null;
    want(entry);
  }

  void _next() {
    while (_reading.length < atOnce) {
      final String key, job;
      if (_looked.isNotEmpty) {
        key = _looked.keys.last;
        job = _looked.remove(key)!;
        _shown.add(key);
      } else if (_ahead.isNotEmpty) {
        key = _ahead.keys.first;
        job = _ahead.remove(key)!;
      } else {
        return;
      }
      _reading.add(key);
      unawaited(_fetch(key, job));
    }
  }

  Future<void> _fetch(String key, String job) async {
    try {
      final paper = await _read(job);
      if (!_closed) _slot(key).value = PaperRead.has(paper);
    } on ApiException catch (err) {
      if (_closed) return;
      if (_shown.contains(key)) {
        _slot(key).value = PaperRead.failed(problem(err));
      } else if (err.status == null) {
        _ahead.clear(); // the hub is away: nothing more is read ahead until the screen names its prints again
      } else {
        _refused.add(key);
      }
    } finally {
      _reading.remove(key);
      _shown.remove(key);
      if (!_closed) _next();
    }
  }

  /// The screen is gone: an answer still on its way is dropped.
  void dispose() {
    _closed = true;
    _looked.clear();
    _ahead.clear();
    for (final slot in _slots.values) {
      slot.dispose();
    }
  }
}

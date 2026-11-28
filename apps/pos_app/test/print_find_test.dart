import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:ui' show TextRange;

import 'package:flutter_test/flutter_test.dart';
import 'package:pos_app/api.dart';
import 'package:pos_app/paper_shelf.dart';
import 'package:pos_app/print_log.dart';

/// The cases the hub's search is held to as well (backend/tests/printing/test_search_cases.py reads the
/// same file): what the app marks on a line is what the hub found the print by.
List<Map<String, dynamic>> searchCases() {
  var dir = Directory.current;
  while (true) {
    final file = File('${dir.path}/backend/tests/printing/search_cases.json');
    if (file.existsSync()) {
      final cases = (jsonDecode(file.readAsStringSync()) as Map<String, dynamic>)['cases'] as List;
      return [for (final c in cases) (c as Map).cast<String, dynamic>()];
    }
    if (dir.parent.path == dir.path) throw StateError('search_cases.json is not above ${Directory.current.path}');
    dir = dir.parent;
  }
}

PrintEntry print(String job, {String printedOn = '10.27.1.14'}) =>
    PrintEntry(jobId: job, atMs: 0, printer: 'wok', name: 'Wok', printedOn: printedOn);

/// A hub that gives a paper when the test says so.
class Papers {
  final asked = <String>[];
  final _waiting = <String, Completer<PrintPaper>>{};

  Future<PrintPaper> read(String job) {
    asked.add(job);
    return (_waiting[job] = Completer<PrintPaper>()).future;
  }

  Future<void> give(String job) async {
    _waiting.remove(job)!.complete(PrintPaper(entry: print(job), pages: const []));
    await pumpEventQueue();
  }

  Future<void> refuse(String job, {int? status = 404}) async {
    _waiting.remove(job)!.completeError(ApiException('no', status: status));
    await pumpEventQueue();
  }
}

void main() {
  group('where a search finds its words on a line', () {
    List<String> words(String line, List<TextRange> hits) => [for (final hit in hits) hit.textInside(line)];

    final cases = searchCases();
    test('the cases are the hub\'s', () => expect(cases.length, greaterThanOrEqualTo(40)));
    for (final c in cases) {
      final q = c['q'] as String;
      if (c['line'] case final String line) {
        test('"$q" on "$line"', () {
          expect(words(line, PrintFind.of(q)!.on(line)), c['marks']);
        });
      } else {
        final (left, right) = (c['left'] as String, c['right'] as String);
        test('"$q" on "$left" | "$right"', () {
          final (onLeft, onRight) = PrintFind.of(q)!.across(left, right);
          expect(words(left, onLeft), c['left_marks']);
          expect(words(right, onRight), c['right_marks']);
        });
      }
    }

    test('nothing typed is no search, and a search is the words with one space between them', () {
      expect(PrintFind.of(''), isNull);
      expect(PrintFind.of('   '), isNull);
      expect(PrintFind.of('  Kung   PAO ')!.q, 'Kung PAO');
      expect(PrintFind.of(' egg  roll'), PrintFind.of('egg roll'));
      expect(PrintFind.of('egg roll'), isNot(PrintFind.of('Egg roll')));
    });

    test('whatever is typed is a search: no sign in it is read as a pattern', () {
      for (final typed in [r'\', r'a\', '(', '[a-', '{1,', '*', '+?', r'$', '-', '/', 'a|b', '😀', r'\d']) {
        final find = PrintFind.of(typed)!;
        expect(words('x $typed y', find.on('x $typed y')), [typed], reason: typed);
        expect(find.on('nothing here'), isEmpty, reason: typed);
      }
    });
  });

  group('the shelf of papers', () {
    late Papers hub;
    late PaperShelf shelf;
    setUp(() {
      hub = Papers();
      shelf = PaperShelf(hub.read, problem: (err) => err.status == null ? 'away' : 'refused ${err.status}');
    });
    tearDown(() => shelf.dispose());

    final listed = [for (var n = 0; n < 10; n++) print('j$n')];

    test('papers read ahead are asked for four at a time, in the order of the list', () async {
      shelf.ahead(listed);
      expect(hub.asked, ['j0', 'j1', 'j2', 'j3']);
      await hub.give('j2');
      expect(hub.asked.last, 'j4');
      expect(shelf.of(listed[2]).value?.paper, isNotNull);
      expect(shelf.of(listed[0]).value, isNull);
      await hub.give('j0');
      await hub.give('j1');
      expect(hub.asked, ['j0', 'j1', 'j2', 'j3', 'j4', 'j5', 'j6']);
    });

    test('the print being looked at goes before the ones read ahead, the last looked at first', () async {
      shelf.ahead(listed);
      shelf
        ..want(listed[8])
        ..want(listed[9])
        ..want(listed[8]);
      expect(hub.asked.length, 4);
      await hub.give('j0');
      await hub.give('j1');
      await hub.give('j3');
      expect(hub.asked.sublist(4), ['j8', 'j9', 'j4']);
    });

    test('a paper is asked for once, however often it is looked at and listed', () async {
      shelf
        ..want(listed[0])
        ..want(listed[0])
        ..ahead(listed.take(2))
        ..want(listed[1]);
      expect(hub.asked, ['j0', 'j1']);
      await hub.give('j0');
      await hub.give('j1');
      shelf
        ..want(listed[0])
        ..ahead(listed.take(2))
        ..again(listed[1]);
      expect(hub.asked, ['j0', 'j1']);
      // printed at another printer since, it is another paper
      shelf.want(print('j0', printedOn: '10.27.1.166'));
      expect(hub.asked, ['j0', 'j1', 'j0']);
    });

    test('a paper read ahead that the hub refused is not said until it is looked at, nor asked ahead again', () async {
      shelf.ahead(listed.take(1));
      await hub.refuse('j0');
      expect(shelf.of(listed[0]).value, isNull);
      shelf.ahead(listed.take(1));
      expect(hub.asked, ['j0']);
      shelf.want(listed[0]);
      expect(hub.asked, ['j0', 'j0']);
      await hub.refuse('j0');
      expect(shelf.of(listed[0]).value?.problem, 'refused 404');
      // refused, it is left alone until it is asked for again
      shelf.want(listed[0]);
      expect(hub.asked.length, 2);
      shelf.again(listed[0]);
      expect(shelf.of(listed[0]).value, isNull);
      await hub.give('j0');
      expect(shelf.of(listed[0]).value?.paper, isNotNull);
    });

    test('one looked at while it was being read ahead says its failure', () async {
      shelf.ahead(listed.take(1));
      shelf.want(listed[0]);
      expect(hub.asked, ['j0']);
      await hub.refuse('j0', status: null);
      expect(shelf.of(listed[0]).value?.problem, 'away');
    });

    test('with the hub away nothing more is read ahead, until the prints are named again', () async {
      shelf.ahead(listed);
      await hub.refuse('j0', status: null);
      await hub.give('j1');
      expect(hub.asked, ['j0', 'j1', 'j2', 'j3']);
      shelf.ahead(listed);
      expect(hub.asked, ['j0', 'j1', 'j2', 'j3', 'j0', 'j4']);
    });

    test('naming no prints stops the reading ahead, and the ones looked at are still read', () async {
      shelf.ahead(listed);
      shelf.ahead(const []);
      shelf.want(listed[7]);
      for (final job in ['j0', 'j1', 'j2', 'j3']) {
        await hub.give(job);
      }
      expect(hub.asked, ['j0', 'j1', 'j2', 'j3', 'j7']);
    });

    test('an answer that comes after the screen is gone is dropped', () async {
      final shelf = PaperShelf(hub.read, problem: (err) => 'no');
      final slot = shelf.of(listed[0]);
      shelf
        ..want(listed[0])
        ..want(listed[1])
        ..dispose();
      await hub.give('j0');
      await hub.refuse('j1');
      shelf
        ..want(listed[2])
        ..ahead(listed)
        ..again(listed[1]);
      expect(hub.asked, ['j0', 'j1']);
      expect(() => slot.value, returnsNormally);
    });
  });
}

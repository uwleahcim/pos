"""A search of the print log, held to the same cases on both sides: the hub finds the prints that have the
words (here), and the app marks the words on their papers (`PrintFind`, read from the same file by
apps/pos_app/test/print_find_test.dart). A line the hub finds is a line the app marks, and no other."""

import json
from pathlib import Path

import pytest

from pos.printing.log import Print, found_in, search_for, words_of

CASES = json.loads((Path(__file__).parent / "search_cases.json").read_text(encoding="utf-8"))["cases"]


def _named(case: dict) -> str:
    return f"{case['q']!r} on {case.get('line', (case.get('left'), case.get('right')))!r}"


@pytest.mark.parametrize("case", CASES, ids=_named)
def test_the_hub_finds_a_line_exactly_when_words_are_marked_on_it(case):
    if "line" in case:
        step = {"k": "line", "text": case["line"]}
    else:
        step = {"k": "cols", "left": case["left"], "right": case["right"]}
    marked = [*case.get("marks", ()), *case.get("left_marks", ()), *case.get("right_marks", ())]
    # the paper alone, as the log keeps its words: what the log's own line says of the print is left out
    paper = words_of(Print("j", 0, printer="p", name="", address=""), [[step]]).partition("\n")[2]
    found = found_in("\n" + paper, search_for(case["q"]))
    assert (found is not None) == bool(marked)


def test_the_cases_are_enough_to_tell_the_two_apart():
    assert len(CASES) >= 40
    assert any("left" in case for case in CASES) and any(not case.get("marks", True) for case in CASES)

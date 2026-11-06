"""The push tokens the screens register."""

from __future__ import annotations

import pytest

from pos.push.devices import PushDevice, PushDevices, clean_device, tokens_of
from pos.settings import DEVICE, EXTENSION

A, B, C = "aa" * 8, "bb" * 8, "cc" * 8


def test_a_screen_registers_its_tokens_and_they_are_found_by_extension_and_by_device():
    registry = PushDevices(clock=lambda: 1_730_000_000.0)
    voip = registry.put(PushDevice(A, "iphone1", "ios", "voip", "302"))
    registry.put(PushDevice(B, "iphone1", "ios", "alert"))
    registry.put(PushDevice(C, "ipad1", "ios", "alert"))
    assert voip.seen_ms == 1_730_000_000_000 and voip.env is None
    assert tokens_of(registry.for_extension("302")) == [A]
    assert registry.for_extension("301") == []
    assert tokens_of(registry.for_device("IPHONE1")) == [B]  # names compared regardless of case
    assert tokens_of(registry.for_device("iphone1", "voip")) == [A]
    assert registry.extensions() == {"302"}
    assert registry.counts() == {"voip": 1, "alert": 2}
    listed = registry.listed()
    assert [d["device"] for d in listed] == ["ipad1", "iphone1", "iphone1"]
    assert listed[0] == {
        "device": "ipad1",
        "platform": "ios",
        "kind": "alert",
        "extension": "",
        "env": None,
        "token": "cccccccc…",
        "seen_ms": 1_730_000_000_000,
    }
    assert registry.remove(C) and not registry.remove(C)
    assert registry.counts() == {"voip": 1, "alert": 1}


def test_a_token_that_moves_keeps_where_apple_took_it_until_apple_says_otherwise():
    registry = PushDevices()
    registry.put(PushDevice(A, "iphone1", "ios", "voip", "302"))
    registry.set_env(A, "sandbox")
    registry.set_env("nobody", "sandbox")  # unknown: nothing happens
    moved = registry.put(PushDevice(A, "iphone1", "ios", "voip", "303"))
    assert moved.env == "sandbox" and registry.extensions() == {"303"}
    told = registry.put(PushDevice(A, "iphone1", "ios", "voip", "303", env="production"))
    assert told.env == "production" and registry.all()[0].env == "production"


def test_a_registration_is_tidied():
    cleaned = clean_device(
        {"token": " ABCDEF0123456789 ", "device": "tab1", "platform": "iOS", "kind": "Alert", "extension": "302"},
        device_pattern=DEVICE,
        extension_pattern=EXTENSION,
    )
    assert cleaned == PushDevice("abcdef0123456789", "tab1", "ios", "alert", "")  # an alert token wakes no extension
    voip = clean_device(
        {"token": "abcdef0123456789", "device": "iphone1", "platform": "ios", "kind": "voip", "extension": " 302 "},
        device_pattern=DEVICE,
        extension_pattern=EXTENSION,
    )
    assert voip.extension == "302"


@pytest.mark.parametrize(
    ("body", "problem"),
    [
        ({"token": "not hex", "device": "tab1", "platform": "ios", "kind": "alert"}, "token"),
        ({"token": "abcd", "device": "tab1", "platform": "ios", "kind": "alert"}, "token"),
        ({"token": A, "device": "tab 1", "platform": "ios", "kind": "alert"}, "device name"),
        ({"token": A, "device": "tab1", "platform": "windows", "kind": "alert"}, "platform"),
        ({"token": A, "device": "tab1", "platform": "ios", "kind": "sms"}, "kind"),
        ({"token": A, "device": "iphone1", "platform": "ios", "kind": "voip"}, "extension it wakes"),
        ({"token": A, "device": "iphone1", "platform": "ios", "kind": "voip", "extension": "3 02"}, "extension"),
    ],
)
def test_a_bad_registration_is_refused_with_the_reason(body, problem):
    with pytest.raises(ValueError, match=problem):
        clean_device(body, device_pattern=DEVICE, extension_pattern=EXTENSION)

"""Taxes: the order module's side of the line. The menu engine attaches a tax class; this decides the charge.

Phase 1 carries the parts one Massachusetts restaurant needs, in the shape the architecture page (section 8)
describes, so more states are rows rather than code: jurisdictions' components, ordered groups, rules
per class and order type (most specific wins), half-up rounding per check or per line, and tax lines
that record what was charged.
"""

from .model import (
    Component,
    Group,
    Rule,
    TaxableLine,
    TaxLine,
    TaxProfile,
    load_profile,
    massachusetts,
)

__all__ = [
    "Component",
    "Group",
    "Rule",
    "TaxLine",
    "TaxProfile",
    "TaxableLine",
    "load_profile",
    "massachusetts",
]

"""The menu engine: catalog, menus, modifiers, recipes and allergens, resolved per order line.

Built from docs/menu-engine-design.md. The engine is a pure package over in-memory definitions;
storage and HTTP come later and wrap these calls unchanged.
"""

from .defs import Definitions, UnitError, money
from .engine import ENGINE_VERSION, MenuEngine
from .request import ComponentRequest, LineRequest, Selection
from .resolved import AllergenProfile, IngredientUsage, KitchenLine, Problem, ResolvedLine, ResolvedModifier

__all__ = [
    "ENGINE_VERSION",
    "AllergenProfile",
    "ComponentRequest",
    "Definitions",
    "IngredientUsage",
    "KitchenLine",
    "LineRequest",
    "MenuEngine",
    "Problem",
    "ResolvedLine",
    "ResolvedModifier",
    "Selection",
    "UnitError",
    "money",
]

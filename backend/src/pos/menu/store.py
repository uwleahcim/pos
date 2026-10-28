"""The menu in PostgreSQL: the menu engine's definitions as the design's schema, with an audit log.

`MenuStore.load()` reads every table into a `Definitions`, which is what the engine resolves against;
`MenuStore.save(defs)` writes a whole `Definitions` back. It compares each row with what is stored, so a
save touches only the rows that changed, keeps every row's id, and writes one audit entry per insert,
update and delete. The latest audit id is the menu's revision: terminals and other hubs compare it to
know when to reload.

The tables follow "Schema sketch" in the Menu Engine Design. Three columns are added: `code` on
`menu_section`, `menu_entry` and `recipe_component` (the in-memory ids, e.g. "dinner/chefs",
"dinner:87"), plus `station_id` on `modifier_option` and `defaults`/`locked` on `recipe_component`,
which the engine already has. A hub creates the tables on start, like the order log.
"""

from __future__ import annotations

import json
import uuid
from collections.abc import Mapping
from dataclasses import dataclass
from datetime import UTC, datetime
from decimal import Decimal
from typing import Any

from psycopg.rows import dict_row
from psycopg.types.json import Jsonb
from psycopg_pool import ConnectionPool

from .defs import (
    Allergen,
    AllergenDecl,
    AllergenOverride,
    Attachment,
    Availability,
    Category,
    Component,
    ComponentOverride,
    Definitions,
    Effect,
    Entry,
    Group,
    Ingredient,
    Item,
    Localizer,
    Menu,
    Option,
    Recipe,
    Section,
    Station,
    Unit,
    Variant,
)

SCHEMA = """
DO $$ BEGIN CREATE TYPE owner_kind AS ENUM ('item','variant','ingredient','category');
EXCEPTION WHEN duplicate_object THEN NULL; END $$;
DO $$ BEGIN CREATE TYPE ingredient_kind AS ENUM ('stock','prep');
EXCEPTION WHEN duplicate_object THEN NULL; END $$;
DO $$ BEGIN CREATE TYPE allergen_level AS ENUM ('contains','may_contain','free');
EXCEPTION WHEN duplicate_object THEN NULL; END $$;
DO $$ BEGIN CREATE TYPE avail_status AS ENUM ('available','sold_out','hidden');
EXCEPTION WHEN duplicate_object THEN NULL; END $$;

CREATE TABLE IF NOT EXISTS unit (
  code      text PRIMARY KEY,
  dimension text NOT NULL CHECK (dimension IN ('mass','volume','count')),
  to_base   numeric(14,6) NOT NULL
);
CREATE TABLE IF NOT EXISTS allergen (
  code     text PRIMARY KEY,
  names    jsonb NOT NULL,
  is_major boolean NOT NULL DEFAULT false,
  sort     int NOT NULL DEFAULT 0
);
CREATE TABLE IF NOT EXISTS station (
  id            uuid PRIMARY KEY,
  code          text UNIQUE NOT NULL,
  names         jsonb NOT NULL,
  printers      text[] NOT NULL DEFAULT '{}',
  cross_contact text[] NOT NULL DEFAULT '{}'
);
CREATE TABLE IF NOT EXISTS category (
  id           uuid PRIMARY KEY,
  parent_id    uuid REFERENCES category DEFERRABLE INITIALLY DEFERRED,
  code         text UNIQUE NOT NULL,
  names        jsonb NOT NULL,
  tax_class    text,
  station_id   uuid REFERENCES station DEFERRABLE INITIALLY DEFERRED,
  prep_minutes int,
  sort         int NOT NULL DEFAULT 0,
  active       boolean NOT NULL DEFAULT true
);
CREATE TABLE IF NOT EXISTS item (
  id           uuid PRIMARY KEY,
  code         text UNIQUE NOT NULL,
  category_id  uuid NOT NULL REFERENCES category DEFERRABLE INITIALLY DEFERRED,
  kind         text NOT NULL DEFAULT 'standard' CHECK (kind IN ('standard','combo')),
  names        jsonb NOT NULL,
  aliases      text[] NOT NULL DEFAULT '{}',
  description  jsonb NOT NULL DEFAULT '{}',
  tax_class    text,
  station_id   uuid REFERENCES station DEFERRABLE INITIALLY DEFERRED,
  prep_minutes int,
  tags         text[] NOT NULL DEFAULT '{}',
  attrs        jsonb NOT NULL DEFAULT '{}',
  active       boolean NOT NULL DEFAULT true,
  sort         int NOT NULL DEFAULT 0
);
CREATE TABLE IF NOT EXISTS item_variant (
  id                  uuid PRIMARY KEY,
  item_id             uuid NOT NULL REFERENCES item ON DELETE CASCADE DEFERRABLE INITIALLY DEFERRED,
  code                text NOT NULL,
  names               jsonb NOT NULL,
  base_price          numeric(10,2) NOT NULL,
  recipe_scale        numeric(8,4) NOT NULL DEFAULT 1,
  component_overrides jsonb NOT NULL DEFAULT '[]',
  plu                 text,
  sort                int NOT NULL DEFAULT 0,
  active              boolean NOT NULL DEFAULT true,
  UNIQUE (item_id, code)
);
CREATE TABLE IF NOT EXISTS modifier_group (
  id               uuid PRIMARY KEY,
  code             text UNIQUE NOT NULL,
  names            jsonb NOT NULL,
  min_select       int NOT NULL DEFAULT 0,
  max_select       int,
  free_count       int NOT NULL DEFAULT 0,
  allow_quantity   boolean NOT NULL DEFAULT false,
  allow_duplicates boolean NOT NULL DEFAULT false,
  display          text NOT NULL DEFAULT 'inline',
  sort             int NOT NULL DEFAULT 0
);
CREATE TABLE IF NOT EXISTS modifier_option (
  id                uuid PRIMARY KEY,
  group_id          uuid NOT NULL REFERENCES modifier_group ON DELETE CASCADE DEFERRABLE INITIALLY DEFERRED,
  code              text NOT NULL,
  names             jsonb NOT NULL,
  kitchen_label     text,
  price_mode        text NOT NULL DEFAULT 'delta' CHECK (price_mode IN ('delta','absolute','free','linked')),
  price             numeric(10,2) NOT NULL DEFAULT 0,
  is_default        boolean NOT NULL DEFAULT false,
  max_qty           int,
  effects           jsonb NOT NULL DEFAULT '[]',
  linked_variant_id uuid REFERENCES item_variant DEFERRABLE INITIALLY DEFERRED,
  child_group_ids   uuid[] NOT NULL DEFAULT '{}',
  station_id        uuid REFERENCES station DEFERRABLE INITIALLY DEFERRED,
  sort              int NOT NULL DEFAULT 0,
  active            boolean NOT NULL DEFAULT true,
  UNIQUE (group_id, code)
);
CREATE TABLE IF NOT EXISTS modifier_attachment (
  id         uuid PRIMARY KEY,
  owner_kind owner_kind NOT NULL CHECK (owner_kind IN ('item','category')),
  owner_id   uuid NOT NULL,
  group_id   uuid NOT NULL REFERENCES modifier_group DEFERRABLE INITIALLY DEFERRED,
  overrides  jsonb NOT NULL DEFAULT '{}',
  excluded   boolean NOT NULL DEFAULT false,
  sort       int NOT NULL DEFAULT 0,
  UNIQUE (owner_kind, owner_id, group_id)
);
CREATE TABLE IF NOT EXISTS menu (
  id       uuid PRIMARY KEY,
  code     text UNIQUE NOT NULL,
  names    jsonb NOT NULL,
  channels text[] NOT NULL,
  schedule jsonb NOT NULL DEFAULT '{}',
  priority int NOT NULL DEFAULT 0,
  active   boolean NOT NULL DEFAULT true
);
CREATE TABLE IF NOT EXISTS menu_section (
  id        uuid PRIMARY KEY,
  menu_id   uuid NOT NULL REFERENCES menu ON DELETE CASCADE DEFERRABLE INITIALLY DEFERRED,
  parent_id uuid REFERENCES menu_section DEFERRABLE INITIALLY DEFERRED,
  code      text NOT NULL,
  names     jsonb NOT NULL,
  display   jsonb NOT NULL DEFAULT '{}',
  sort      int NOT NULL DEFAULT 0,
  UNIQUE (menu_id, code)
);
CREATE TABLE IF NOT EXISTS menu_entry (
  id              uuid PRIMARY KEY,
  menu_id         uuid NOT NULL REFERENCES menu ON DELETE CASCADE DEFERRABLE INITIALLY DEFERRED,
  section_id      uuid NOT NULL REFERENCES menu_section DEFERRABLE INITIALLY DEFERRED,
  item_id         uuid NOT NULL REFERENCES item DEFERRABLE INITIALLY DEFERRED,
  code            text NOT NULL,
  number          text,
  variant_ids     uuid[],
  price_overrides jsonb NOT NULL DEFAULT '{}',
  availability    jsonb NOT NULL DEFAULT '{}',
  visible         boolean NOT NULL DEFAULT true,
  featured        boolean NOT NULL DEFAULT false,
  display         jsonb NOT NULL DEFAULT '{}',
  sort            int NOT NULL DEFAULT 0,
  UNIQUE (menu_id, code),
  UNIQUE (menu_id, number) DEFERRABLE INITIALLY DEFERRED
);
CREATE TABLE IF NOT EXISTS availability_state (
  target_id uuid PRIMARY KEY,
  status    avail_status NOT NULL,
  until     timestamptz,
  reason    text,
  set_by    text,
  set_at    timestamptz NOT NULL DEFAULT now()
);
CREATE TABLE IF NOT EXISTS ingredient (
  id                    uuid PRIMARY KEY,
  code                  text UNIQUE NOT NULL,
  names                 jsonb NOT NULL,
  kind                  ingredient_kind NOT NULL,
  category              text,
  base_unit             text NOT NULL REFERENCES unit DEFERRABLE INITIALLY DEFERRED,
  each_grams            numeric(10,3),
  grams_per_ml          numeric(10,4),
  yield_pct             numeric(5,2) NOT NULL DEFAULT 100,
  cost_per_base_unit    numeric(12,6) NOT NULL DEFAULT 0,
  dietary_tags          text[] NOT NULL DEFAULT '{}',
  allergens_reviewed_at timestamptz,
  track_stock           boolean NOT NULL DEFAULT true,
  critical              boolean NOT NULL DEFAULT false,
  active                boolean NOT NULL DEFAULT true
);
CREATE TABLE IF NOT EXISTS ingredient_allergen (
  ingredient_id uuid NOT NULL REFERENCES ingredient ON DELETE CASCADE DEFERRABLE INITIALLY DEFERRED,
  allergen_code text NOT NULL REFERENCES allergen DEFERRABLE INITIALLY DEFERRED,
  level         allergen_level NOT NULL CHECK (level <> 'free'),
  verified      boolean NOT NULL DEFAULT false,
  source        text,
  PRIMARY KEY (ingredient_id, allergen_code)
);
CREATE TABLE IF NOT EXISTS item_allergen_override (
  id            uuid PRIMARY KEY,
  owner_kind    owner_kind NOT NULL CHECK (owner_kind IN ('item','variant')),
  owner_id      uuid NOT NULL,
  allergen_code text NOT NULL REFERENCES allergen DEFERRABLE INITIALLY DEFERRED,
  level         allergen_level NOT NULL,
  reason        text NOT NULL,
  set_by        text,
  set_at        timestamptz NOT NULL DEFAULT now()
);
CREATE TABLE IF NOT EXISTS recipe (
  id         uuid PRIMARY KEY,
  owner_kind owner_kind NOT NULL,
  owner_id   uuid NOT NULL,
  version    int NOT NULL,
  yield_qty  numeric(12,3) NOT NULL DEFAULT 1,
  yield_unit text REFERENCES unit DEFERRABLE INITIALLY DEFERRED,
  notes      text,
  is_current boolean NOT NULL DEFAULT true,
  created_at timestamptz NOT NULL DEFAULT now(),
  created_by text,
  UNIQUE (owner_kind, owner_id, version)
);
CREATE UNIQUE INDEX IF NOT EXISTS recipe_current ON recipe (owner_kind, owner_id) WHERE is_current;
CREATE TABLE IF NOT EXISTS recipe_component (
  id             uuid PRIMARY KEY,
  recipe_id      uuid NOT NULL REFERENCES recipe ON DELETE CASCADE DEFERRABLE INITIALLY DEFERRED,
  code           text NOT NULL,
  component_kind text NOT NULL DEFAULT 'ingredient' CHECK (component_kind IN ('ingredient','variant')),
  ingredient_id  uuid REFERENCES ingredient DEFERRABLE INITIALLY DEFERRED,
  variant_id     uuid REFERENCES item_variant DEFERRABLE INITIALLY DEFERRED,
  qty            numeric(12,4) NOT NULL,
  unit           text NOT NULL REFERENCES unit DEFERRABLE INITIALLY DEFERRED,
  role           text,
  optional       boolean NOT NULL DEFAULT false,
  scales         boolean NOT NULL DEFAULT true,
  defaults       jsonb NOT NULL DEFAULT '{}',
  locked         boolean NOT NULL DEFAULT false,
  sort           int NOT NULL DEFAULT 0,
  UNIQUE (recipe_id, code)
);
CREATE INDEX IF NOT EXISTS recipe_component_ingredient ON recipe_component (ingredient_id);
CREATE INDEX IF NOT EXISTS recipe_component_variant ON recipe_component (variant_id);
CREATE TABLE IF NOT EXISTS audit_log (
  id         bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  at         timestamptz NOT NULL DEFAULT now(),
  actor      text,
  table_name text NOT NULL,
  row_id     text NOT NULL,
  action     text NOT NULL,
  before     jsonb,
  after      jsonb
);
"""
# audit_log.row_id is text rather than the sketch's uuid: unit and allergen rows are keyed by their code.


@dataclass(frozen=True)
class SaveResult:
    revision: int
    inserted: int
    updated: int
    deleted: int

    @property
    def changed(self) -> int:
        return self.inserted + self.updated + self.deleted


class _Ids:
    """In-memory code <-> row id, per table, filled as tables are written or read."""

    def __init__(self) -> None:
        self.by_code: dict[str, dict[str, Any]] = {}
        self.by_id: dict[str, dict[Any, str]] = {}

    def put(self, table: str, code: str, row_id: Any) -> None:
        self.by_code.setdefault(table, {})[code] = row_id
        self.by_id.setdefault(table, {})[row_id] = code

    def id(self, table: str, code: str | None) -> Any:
        if code is None:
            return None
        try:
            return self.by_code[table][code]
        except KeyError:
            raise ValueError(f"{table} {code!r} does not exist") from None

    def code(self, table: str, row_id: Any) -> str | None:
        return None if row_id is None else self.by_id.get(table, {}).get(row_id)


@dataclass(frozen=True)
class _Table:
    """One table: the columns that identify a row without its id, and whether it has a uuid id."""

    name: str
    key: tuple[str, ...]
    uuid_id: bool = True
    pk: tuple[str, ...] = ("id",)


TABLES = {
    t.name: t
    for t in (
        _Table("unit", ("code",), uuid_id=False, pk=("code",)),
        _Table("allergen", ("code",), uuid_id=False, pk=("code",)),
        _Table("station", ("code",)),
        _Table("category", ("code",)),
        _Table("item", ("code",)),
        _Table("item_variant", ("item_id", "code")),
        _Table("modifier_group", ("code",)),
        _Table("modifier_option", ("group_id", "code")),
        _Table("modifier_attachment", ("owner_kind", "owner_id", "group_id")),
        _Table("menu", ("code",)),
        _Table("menu_section", ("menu_id", "code")),
        _Table("menu_entry", ("menu_id", "code")),
        _Table("ingredient", ("code",)),
        _Table(
            "ingredient_allergen",
            ("ingredient_id", "allergen_code"),
            uuid_id=False,
            pk=("ingredient_id", "allergen_code"),
        ),
        _Table("item_allergen_override", ("owner_kind", "owner_id", "allergen_code")),
        _Table("recipe", ("owner_kind", "owner_id", "version")),
        _Table("recipe_component", ("recipe_id", "code")),
    )
}
ORDER = list(TABLES)  # parents before children; deletes run in reverse


class MenuStore:
    def __init__(self, dsn: str, *, pool_size: int = 2) -> None:
        self._pool = ConnectionPool(dsn, min_size=1, max_size=pool_size, open=True, kwargs={"row_factory": dict_row})
        if self.role == "primary":
            with self._pool.connection() as conn:
                conn.execute(SCHEMA)

    @property
    def role(self) -> str:
        with self._pool.connection() as conn:
            row = conn.execute("SELECT pg_is_in_recovery() AS standby").fetchone()
        return "replica" if row and row["standby"] else "primary"

    def close(self) -> None:
        self._pool.close()

    def revision(self) -> int:
        """The id of the last change to any definition; 0 for an empty menu."""
        with self._pool.connection() as conn:
            row = conn.execute("SELECT COALESCE(MAX(id), 0) AS rev FROM audit_log").fetchone()
        return int(row["rev"]) if row else 0

    def is_empty(self) -> bool:
        with self._pool.connection() as conn:
            return conn.execute("SELECT 1 FROM item LIMIT 1").fetchone() is None

    # --- reading --------------------------------------------------------------------------------

    def load(self, localizer: Localizer | None = None) -> Definitions:
        with self._pool.connection() as conn:
            rows = {name: conn.execute(f"SELECT * FROM {name}").fetchall() for name in ORDER}  # noqa: S608
        return _definitions(rows, localizer)

    def availability(self) -> dict[str, Availability]:
        """The 86 board: sold-out or hidden variants and options, by their in-memory ids."""
        with self._pool.connection() as conn:
            states = conn.execute("SELECT * FROM availability_state").fetchall()
            ids = _target_codes(conn)
        out = {}
        for s in states:
            target = ids.get(s["target_id"])
            if target is not None:
                out[target] = Availability(target, s["status"], s["until"], s["reason"], s["set_by"], s["set_at"])
        return out

    def set_availability(self, state: Availability | None, target: str) -> None:
        """Store one 86 change (`None` = back to available)."""
        with self._pool.connection() as conn, conn.transaction():
            row_id = _target_ids(conn).get(target)
            if row_id is None:
                raise ValueError(f"no variant or option {target!r}")
            if state is None or state.status == "available":
                conn.execute("DELETE FROM availability_state WHERE target_id = %s", (row_id,))
                return
            conn.execute(
                """INSERT INTO availability_state (target_id, status, until, reason, set_by, set_at)
                   VALUES (%s, %s, %s, %s, %s, %s)
                   ON CONFLICT (target_id) DO UPDATE SET status = EXCLUDED.status, until = EXCLUDED.until,
                   reason = EXCLUDED.reason, set_by = EXCLUDED.set_by, set_at = EXCLUDED.set_at""",
                (row_id, state.status, state.until, state.reason, state.set_by, state.set_at or datetime.now(UTC)),
            )

    # --- writing --------------------------------------------------------------------------------

    def save(self, defs: Definitions, *, actor: str | None = None) -> SaveResult:
        """Make the stored menu equal `defs`, in one transaction: rows are inserted, updated or deleted
        only where they differ, ids are kept, and each change is written to the audit log."""
        _check_ids(defs)
        with self._pool.connection() as conn, conn.transaction():
            conn.execute("SET CONSTRAINTS ALL DEFERRED")
            conn.execute("SELECT pg_advisory_xact_lock(7032)")  # one menu writer at a time
            existing = {name: conn.execute(f"SELECT * FROM {name}").fetchall() for name in ORDER}  # noqa: S608
            ids = _Ids()
            _remember(existing, ids)
            wanted = _rows(defs, ids)
            counts = {"insert": 0, "update": 0, "delete": 0}
            audit: list[tuple[str, str, str, Any, Any]] = []
            for name in ORDER:
                table = TABLES[name]
                have = {_key(table, row): row for row in existing[name]}
                want = {_key(table, row): row for row in wanted[name]}
                for key, row in want.items():
                    old = have.get(key)
                    if old is None:
                        _insert(conn, name, row)
                        audit.append((name, _row_id(table, row), "insert", None, row))
                        counts["insert"] += 1
                    elif _plain(old) != _plain(row):
                        _update(conn, table, row)
                        audit.append((name, _row_id(table, row), "update", old, row))
                        counts["update"] += 1
            for name in reversed(ORDER):
                table = TABLES[name]
                want_keys = {_key(table, row) for row in wanted[name]}
                for row in existing[name]:
                    if _key(table, row) not in want_keys:
                        _delete(conn, table, row)
                        audit.append((name, _row_id(table, row), "delete", row, None))
                        counts["delete"] += 1
            for name, row_id, action, before, after in audit:
                conn.execute(
                    "INSERT INTO audit_log (actor, table_name, row_id, action, before, after)"
                    " VALUES (%s, %s, %s, %s, %s, %s)",
                    (
                        actor,
                        name,
                        row_id,
                        action,
                        None if before is None else Jsonb(_plain(before)),
                        None if after is None else Jsonb(_plain(after)),
                    ),
                )
            row = conn.execute("SELECT COALESCE(MAX(id), 0) AS rev FROM audit_log").fetchone()
        return SaveResult(int(row["rev"]), counts["insert"], counts["update"], counts["delete"])

    def audit(self, limit: int = 50) -> list[dict[str, Any]]:
        """The latest changes, newest first."""
        with self._pool.connection() as conn:
            return conn.execute("SELECT * FROM audit_log ORDER BY id DESC LIMIT %s", (limit,)).fetchall()


# --- Definitions -> rows -------------------------------------------------------------------------------


def _check_ids(defs: Definitions) -> None:
    """The in-memory ids are rebuilt from codes on load, so they must follow the conventions in defs.py."""
    wrong = [v.id for v in defs.variants.values() if v.id != f"{v.item}:{v.code}"]
    wrong += [o.id for o in defs.options.values() if o.id != f"{o.group}:{o.code}"]
    wrong += [r.id for r in defs.recipes if r.id != f"{r.owner}@{r.version}"]
    if wrong:
        raise ValueError("ids that do not match their codes: " + ", ".join(wrong[:10]))


def _new_id(ids: _Ids, table: str, code: str) -> Any:
    existing = ids.by_code.get(table, {}).get(code)
    if existing is not None:
        return existing
    row_id = uuid.uuid4()
    ids.put(table, code, row_id)
    return row_id


def _rows(defs: Definitions, ids: _Ids) -> dict[str, list[dict[str, Any]]]:
    """Every row `defs` needs, with ids reused from `ids` where the row already exists."""
    out: dict[str, list[dict[str, Any]]] = {name: [] for name in ORDER}

    out["unit"] = [{"code": u.code, "dimension": u.dimension, "to_base": u.to_base} for u in defs.units.values()]
    out["allergen"] = [
        {"code": a.code, "names": dict(a.names), "is_major": a.is_major, "sort": a.sort}
        for a in defs.allergens.values()
    ]
    for s in defs.stations.values():
        out["station"].append(
            {
                "id": _new_id(ids, "station", s.code),
                "code": s.code,
                "names": dict(s.names),
                "printers": list(s.printers),
                "cross_contact": sorted(s.cross_contact),
            }
        )
    for c in defs.categories.values():
        _new_id(ids, "category", c.code)
    for c in defs.categories.values():
        out["category"].append(
            {
                "id": ids.id("category", c.code),
                "parent_id": ids.id("category", c.parent),
                "code": c.code,
                "names": dict(c.names),
                "tax_class": c.tax_class,
                "station_id": ids.id("station", c.station),
                "prep_minutes": c.prep_minutes,
                "sort": c.sort,
                "active": c.active,
            }
        )
    for i in defs.items.values():
        out["item"].append(
            {
                "id": _new_id(ids, "item", i.code),
                "code": i.code,
                "category_id": ids.id("category", i.category),
                "kind": i.kind,
                "names": dict(i.names),
                "aliases": list(i.aliases),
                "description": dict(i.description),
                "tax_class": i.tax_class,
                "station_id": ids.id("station", i.station),
                "prep_minutes": i.prep_minutes,
                "tags": list(i.tags),
                "attrs": dict(i.attrs),
                "active": i.active,
                "sort": i.sort,
            }
        )
    for v in defs.variants.values():
        out["item_variant"].append(
            {
                "id": _new_id(ids, "item_variant", v.id),
                "item_id": ids.id("item", v.item),
                "code": v.code,
                "names": dict(v.names),
                "base_price": v.base_price,
                "recipe_scale": v.recipe_scale,
                "component_overrides": [_dict(c) for c in v.component_overrides],
                "plu": v.plu,
                "sort": v.sort,
                "active": v.active,
            }
        )
    for g in defs.groups.values():
        out["modifier_group"].append(
            {
                "id": _new_id(ids, "modifier_group", g.code),
                "code": g.code,
                "names": dict(g.names),
                "min_select": g.min_select,
                "max_select": g.max_select,
                "free_count": g.free_count,
                "allow_quantity": g.allow_quantity,
                "allow_duplicates": g.allow_duplicates,
                "display": g.display,
                "sort": g.sort,
            }
        )
    for o in defs.options.values():
        out["modifier_option"].append(
            {
                "id": _new_id(ids, "modifier_option", o.id),
                "group_id": ids.id("modifier_group", o.group),
                "code": o.code,
                "names": dict(o.names),
                "kitchen_label": o.kitchen_label,
                "price_mode": o.price_mode,
                "price": o.price,
                "is_default": o.is_default,
                "max_qty": o.max_qty,
                "effects": [_dict(e) for e in o.effects],
                "linked_variant_id": ids.id("item_variant", o.linked_variant),
                "child_group_ids": [ids.id("modifier_group", g) for g in o.child_groups],
                "station_id": ids.id("station", o.station),
                "sort": o.sort,
                "active": o.active,
            }
        )
    for a in defs.attachments:
        owner_table = "item" if a.owner_kind == "item" else "category"
        owner_id = ids.id(owner_table, a.owner)
        group_id = ids.id("modifier_group", a.group)
        code = f"{a.owner_kind}:{a.owner}:{a.group}"
        out["modifier_attachment"].append(
            {
                "id": _new_id(ids, "modifier_attachment", code),
                "owner_kind": a.owner_kind,
                "owner_id": owner_id,
                "group_id": group_id,
                "overrides": dict(a.overrides),
                "excluded": a.excluded,
                "sort": a.sort,
            }
        )
    for m in defs.menus.values():
        out["menu"].append(
            {
                "id": _new_id(ids, "menu", m.code),
                "code": m.code,
                "names": dict(m.names),
                "channels": list(m.channels),
                "schedule": dict(m.schedule),
                "priority": m.priority,
                "active": m.active,
            }
        )
    for s in defs.sections.values():
        _new_id(ids, "menu_section", s.id)
    for s in defs.sections.values():
        out["menu_section"].append(
            {
                "id": ids.id("menu_section", s.id),
                "menu_id": ids.id("menu", s.menu),
                "parent_id": ids.id("menu_section", s.parent),
                "code": s.id,
                "names": dict(s.names),
                "display": dict(s.display),
                "sort": s.sort,
            }
        )
    for e in defs.entries:
        out["menu_entry"].append(
            {
                "id": _new_id(ids, "menu_entry", e.id),
                "menu_id": ids.id("menu", e.menu),
                "section_id": ids.id("menu_section", e.section),
                "item_id": ids.id("item", e.item),
                "code": e.id,
                "number": e.number,
                "variant_ids": None if e.variants is None else [ids.id("item_variant", v) for v in e.variants],
                "price_overrides": {str(ids.id("item_variant", v)): str(p) for v, p in e.price_overrides.items()},
                "availability": dict(e.availability),
                "visible": e.visible,
                "featured": e.featured,
                "display": dict(e.display),
                "sort": e.sort,
            }
        )
    for ing in defs.ingredients.values():
        row_id = _new_id(ids, "ingredient", ing.code)
        out["ingredient"].append(
            {
                "id": row_id,
                "code": ing.code,
                "names": dict(ing.names),
                "kind": ing.kind,
                "category": ing.category,
                "base_unit": ing.base_unit,
                "each_grams": ing.each_grams,
                "grams_per_ml": ing.grams_per_ml,
                "yield_pct": ing.yield_pct,
                "cost_per_base_unit": ing.cost_per_base_unit,
                "dietary_tags": list(ing.dietary_tags),
                "allergens_reviewed_at": ing.allergens_reviewed_at,
                "track_stock": ing.track_stock,
                "critical": ing.critical,
                "active": ing.active,
            }
        )
        for decl in ing.allergens:
            out["ingredient_allergen"].append(
                {
                    "ingredient_id": row_id,
                    "allergen_code": decl.allergen,
                    "level": decl.level,
                    "verified": decl.verified,
                    "source": decl.source,
                }
            )
    for ov in defs.overrides:
        owner_id = ids.id("item" if ov.owner_kind == "item" else "item_variant", ov.owner)
        code = f"{ov.owner_kind}:{ov.owner}:{ov.allergen}"
        existing_set_at = ids.by_code.get("_override_set_at", {}).get(code)
        out["item_allergen_override"].append(
            {
                "id": _new_id(ids, "item_allergen_override", code),
                "owner_kind": ov.owner_kind,
                "owner_id": owner_id,
                "allergen_code": ov.allergen,
                "level": ov.level,
                "reason": ov.reason,
                "set_by": ov.set_by,
                "set_at": existing_set_at or datetime.now(UTC),
            }
        )
    for r in defs.recipes:
        owner_table = {"item": "item", "variant": "item_variant", "ingredient": "ingredient"}[r.owner_kind]
        recipe_id = _new_id(ids, "recipe", r.id)
        code = r.id
        out["recipe"].append(
            {
                "id": recipe_id,
                "owner_kind": r.owner_kind,
                "owner_id": ids.id(owner_table, r.owner),
                "version": r.version,
                "yield_qty": r.yield_qty,
                "yield_unit": r.yield_unit,
                "notes": r.notes,
                "is_current": r.is_current,
                "created_at": ids.by_code.get("_recipe_created_at", {}).get(code) or datetime.now(UTC),
                "created_by": ids.by_code.get("_recipe_created_by", {}).get(code),
            }
        )
        for c in r.components:
            out["recipe_component"].append(
                {
                    "id": _new_id(ids, "recipe_component", f"{r.id}/{c.id}"),
                    "recipe_id": recipe_id,
                    "code": c.id,
                    "component_kind": c.kind,
                    "ingredient_id": ids.id("ingredient", c.ref) if c.kind == "ingredient" else None,
                    "variant_id": ids.id("item_variant", c.ref) if c.kind == "variant" else None,
                    "qty": c.qty,
                    "unit": c.unit,
                    "role": c.role,
                    "optional": c.optional,
                    "scales": c.scales,
                    "defaults": dict(c.defaults),
                    "locked": c.locked,
                    "sort": c.sort,
                }
            )
    return out


def _remember(rows: Mapping[str, list[dict[str, Any]]], ids: _Ids) -> None:
    """Fill `ids` with every stored row's in-memory code, so a save keeps ids and a load can name rows."""
    for r in rows["station"]:
        ids.put("station", r["code"], r["id"])
    for r in rows["category"]:
        ids.put("category", r["code"], r["id"])
    for r in rows["item"]:
        ids.put("item", r["code"], r["id"])
    for r in rows["item_variant"]:
        ids.put("item_variant", f"{ids.code('item', r['item_id'])}:{r['code']}", r["id"])
    for r in rows["modifier_group"]:
        ids.put("modifier_group", r["code"], r["id"])
    for r in rows["modifier_option"]:
        ids.put("modifier_option", f"{ids.code('modifier_group', r['group_id'])}:{r['code']}", r["id"])
    for r in rows["modifier_attachment"]:
        owner = ids.code("item" if r["owner_kind"] == "item" else "category", r["owner_id"])
        ids.put(
            "modifier_attachment", f"{r['owner_kind']}:{owner}:{ids.code('modifier_group', r['group_id'])}", r["id"]
        )
    for r in rows["menu"]:
        ids.put("menu", r["code"], r["id"])
    for r in rows["menu_section"]:
        ids.put("menu_section", r["code"], r["id"])
    for r in rows["menu_entry"]:
        ids.put("menu_entry", r["code"], r["id"])
    for r in rows["ingredient"]:
        ids.put("ingredient", r["code"], r["id"])
    for r in rows["item_allergen_override"]:
        table = "item" if r["owner_kind"] == "item" else "item_variant"
        code = f"{r['owner_kind']}:{ids.code(table, r['owner_id'])}:{r['allergen_code']}"
        ids.put("item_allergen_override", code, r["id"])
        ids.by_code.setdefault("_override_set_at", {})[code] = r["set_at"]
    for r in rows["recipe"]:
        table = {"item": "item", "variant": "item_variant", "ingredient": "ingredient"}[r["owner_kind"]]
        code = f"{ids.code(table, r['owner_id'])}@{r['version']}"
        ids.put("recipe", code, r["id"])
        ids.by_code.setdefault("_recipe_created_at", {})[code] = r["created_at"]
        ids.by_code.setdefault("_recipe_created_by", {})[code] = r["created_by"]
    for r in rows["recipe_component"]:
        ids.put("recipe_component", f"{ids.code('recipe', r['recipe_id'])}/{r['code']}", r["id"])


# --- rows -> Definitions -------------------------------------------------------------------------------


def _definitions(rows: Mapping[str, list[dict[str, Any]]], localizer: Localizer | None) -> Definitions:
    ids = _Ids()
    _remember(rows, ids)
    defs = Definitions(localizer)
    by_sort = lambda rs: sorted(rs, key=lambda r: (r.get("sort", 0), str(r.get("code", ""))))  # noqa: E731
    for r in rows["unit"]:
        defs.add(Unit(r["code"], r["dimension"], r["to_base"]))
    for r in rows["allergen"]:
        defs.add(Allergen(r["code"], r["names"], r["is_major"], r["sort"]))
    for r in rows["station"]:
        defs.add(Station(r["code"], r["names"], tuple(r["printers"]), frozenset(r["cross_contact"])))
    for r in by_sort(rows["category"]):
        defs.add(
            Category(
                r["code"],
                r["names"],
                ids.code("category", r["parent_id"]),
                r["tax_class"],
                ids.code("station", r["station_id"]),
                r["prep_minutes"],
                r["sort"],
                r["active"],
            )
        )
    for r in by_sort(rows["item"]):
        defs.add(
            Item(
                r["code"],
                ids.code("category", r["category_id"]),
                r["names"],
                r["kind"],
                tuple(r["aliases"]),
                r["description"],
                r["tax_class"],
                ids.code("station", r["station_id"]),
                r["prep_minutes"],
                tuple(r["tags"]),
                r["attrs"],
                r["active"],
                r["sort"],
            )
        )
    for r in by_sort(rows["item_variant"]):
        defs.add(
            Variant(
                ids.code("item_variant", r["id"]),
                ids.code("item", r["item_id"]),
                r["code"],
                r["names"],
                r["base_price"],
                r["recipe_scale"],
                tuple(
                    ComponentOverride(c["role"], c["ingredient"], Decimal(c["qty"]), c["unit"])
                    for c in r["component_overrides"]
                ),
                r["plu"],
                r["sort"],
                r["active"],
            )
        )
    for r in by_sort(rows["modifier_group"]):
        defs.add(
            Group(
                r["code"],
                r["names"],
                r["min_select"],
                r["max_select"],
                r["free_count"],
                r["allow_quantity"],
                r["allow_duplicates"],
                r["display"],
                r["sort"],
            )
        )
    for r in by_sort(rows["modifier_option"]):
        defs.add(
            Option(
                ids.code("modifier_option", r["id"]),
                ids.code("modifier_group", r["group_id"]),
                r["code"],
                r["names"],
                r["kitchen_label"],
                r["price_mode"],
                r["price"],
                r["is_default"],
                r["max_qty"],
                tuple(_effect(e) for e in r["effects"]),
                ids.code("item_variant", r["linked_variant_id"]),
                tuple(ids.code("modifier_group", g) for g in r["child_group_ids"]),
                ids.code("station", r["station_id"]),
                r["sort"],
                r["active"],
            )
        )
    for r in by_sort(rows["modifier_attachment"]):
        owner_table = "item" if r["owner_kind"] == "item" else "category"
        defs.add(
            Attachment(
                r["owner_kind"],
                ids.code(owner_table, r["owner_id"]),
                ids.code("modifier_group", r["group_id"]),
                _overrides(r["overrides"]),
                r["excluded"],
                r["sort"],
            )
        )
    for r in rows["menu"]:
        defs.add(Menu(r["code"], r["names"], tuple(r["channels"]), r["schedule"], r["priority"], r["active"]))
    for r in by_sort(rows["menu_section"]):
        defs.add(
            Section(
                r["code"],
                ids.code("menu", r["menu_id"]),
                r["names"],
                ids.code("menu_section", r["parent_id"]),
                r["display"],
                r["sort"],
            )
        )
    for r in by_sort(rows["menu_entry"]):
        defs.add(
            Entry(
                r["code"],
                ids.code("menu", r["menu_id"]),
                ids.code("menu_section", r["section_id"]),
                ids.code("item", r["item_id"]),
                r["number"],
                None if r["variant_ids"] is None else tuple(ids.code("item_variant", v) for v in r["variant_ids"]),
                {ids.code("item_variant", uuid.UUID(v)): Decimal(p) for v, p in r["price_overrides"].items()},
                r["availability"],
                r["visible"],
                r["featured"],
                r["display"],
                r["sort"],
            )
        )
    allergens: dict[Any, list[AllergenDecl]] = {}
    for r in rows["ingredient_allergen"]:
        allergens.setdefault(r["ingredient_id"], []).append(
            AllergenDecl(r["allergen_code"], r["level"], r["verified"], r["source"])
        )
    for r in rows["ingredient"]:
        defs.add(
            Ingredient(
                r["code"],
                r["names"],
                r["kind"],
                r["base_unit"],
                r["category"],
                r["each_grams"],
                r["grams_per_ml"],
                r["yield_pct"],
                r["cost_per_base_unit"],
                tuple(r["dietary_tags"]),
                tuple(sorted(allergens.get(r["id"], ()), key=lambda d: d.allergen)),
                r["allergens_reviewed_at"],
                r["track_stock"],
                r["critical"],
                r["active"],
            )
        )
    for r in rows["item_allergen_override"]:
        table = "item" if r["owner_kind"] == "item" else "item_variant"
        defs.add(
            AllergenOverride(
                r["owner_kind"],
                ids.code(table, r["owner_id"]),
                r["allergen_code"],
                r["level"],
                r["reason"],
                r["set_by"],
            )
        )
    components: dict[Any, list[Component]] = {}
    for r in sorted(rows["recipe_component"], key=lambda r: (r["sort"], r["code"])):
        kind = r["component_kind"]
        ref = (
            ids.code("ingredient", r["ingredient_id"])
            if kind == "ingredient"
            else ids.code("item_variant", r["variant_id"])
        )
        components.setdefault(r["recipe_id"], []).append(
            Component(
                r["code"],
                kind,
                ref,
                r["qty"],
                r["unit"],
                r["role"],
                r["optional"],
                r["scales"],
                r["sort"],
                r["defaults"],
                r["locked"],
            )
        )
    for r in rows["recipe"]:
        defs.add(
            Recipe(
                ids.code("recipe", r["id"]),
                r["owner_kind"],
                ids.code(
                    {"item": "item", "variant": "item_variant", "ingredient": "ingredient"}[r["owner_kind"]],
                    r["owner_id"],
                ),
                r["version"],
                tuple(components.get(r["id"], ())),
                r["yield_qty"],
                r["yield_unit"],
                r["notes"],
                r["is_current"],
            )
        )
    return defs


def _effect(e: Mapping[str, Any]) -> Effect:
    dec = lambda v: None if v is None else Decimal(v)  # noqa: E731
    return Effect(e["op"], e.get("ingredient"), e.get("role"), dec(e.get("qty")), e.get("unit"), dec(e.get("factor")))


def _overrides(o: Mapping[str, Any]) -> dict[str, Any]:
    out = dict(o)
    if "prices" in out:
        out["prices"] = {k: Decimal(v) for k, v in out["prices"].items()}
    return out


def _target_ids(conn) -> dict[str, Any]:
    """Every variant and option by its in-memory id: what an 86 can point at."""
    rows = conn.execute(
        """SELECT i.code || ':' || v.code AS code, v.id FROM item_variant v JOIN item i ON i.id = v.item_id
           UNION ALL
           SELECT g.code || ':' || o.code, o.id FROM modifier_option o JOIN modifier_group g ON g.id = o.group_id"""
    ).fetchall()
    return {r["code"]: r["id"] for r in rows}


def _target_codes(conn) -> dict[Any, str]:
    return {row_id: code for code, row_id in _target_ids(conn).items()}


# --- SQL helpers -------------------------------------------------------------------------------------


def _key(table: _Table, row: Mapping[str, Any]) -> tuple:
    return tuple(_plain_value(row[c]) for c in table.key)


def _row_id(table: _Table, row: Mapping[str, Any]) -> str:
    return "/".join(str(row[c]) for c in table.pk)


JSON_COLUMNS = {
    "names", "description", "attrs", "component_overrides", "effects", "overrides", "schedule", "display",
    "price_overrides", "availability", "defaults",
}  # fmt: skip
TEXT_COLUMNS = {("modifier_group", "display")}  # a JSON column name elsewhere, plain text here


def _params(table: str, row: Mapping[str, Any]) -> dict[str, Any]:
    return {k: Jsonb(_plain(v)) if k in JSON_COLUMNS and (table, k) not in TEXT_COLUMNS else v for k, v in row.items()}


def _insert(conn, name: str, row: Mapping[str, Any]) -> None:
    cols = list(row)
    conn.execute(
        f"INSERT INTO {name} ({', '.join(cols)}) VALUES ({', '.join(f'%({c})s' for c in cols)})",  # noqa: S608
        _params(name, row),
    )


def _update(conn, table: _Table, row: Mapping[str, Any]) -> None:
    cols = [c for c in row if c not in table.pk]
    where = " AND ".join(f"{c} = %({c})s" for c in table.pk)
    conn.execute(
        f"UPDATE {table.name} SET {', '.join(f'{c} = %({c})s' for c in cols)} WHERE {where}",  # noqa: S608
        _params(table.name, row),
    )


def _delete(conn, table: _Table, row: Mapping[str, Any]) -> None:
    where = " AND ".join(f"{c} = %({c})s" for c in table.pk)
    conn.execute(f"DELETE FROM {table.name} WHERE {where}", {c: row[c] for c in table.pk})  # noqa: S608


def _plain(value: Any) -> Any:
    """A JSON-ready form for comparing a stored row with a wanted one and for the audit log."""
    if isinstance(value, Mapping):
        return {str(k): _plain(v) for k, v in sorted(value.items(), key=lambda kv: str(kv[0]))}
    if isinstance(value, (list, tuple, set, frozenset)):
        return [_plain(v) for v in value]
    return _plain_value(value)


def _plain_value(value: Any) -> Any:
    if isinstance(value, Decimal):
        return format(value.normalize(), "f")
    if isinstance(value, uuid.UUID):
        return str(value)
    if isinstance(value, datetime):
        return value.astimezone(UTC).isoformat()
    if isinstance(value, (list, tuple)):
        return json.dumps([_plain_value(v) for v in value])
    return value


def _dict(obj: Any) -> dict[str, Any]:
    """A dataclass as a dict without empty values, Decimals as text (for JSONB)."""
    out = {}
    for k, v in vars(obj).items():
        if v is None:
            continue
        out[k] = str(v) if isinstance(v, Decimal) else v
    return out

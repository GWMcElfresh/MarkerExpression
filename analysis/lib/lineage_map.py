"""Load and apply the closed Cell Ontology -> lineage map."""

from __future__ import annotations

from pathlib import Path
from typing import Mapping

import yaml

DEFAULT_LINEAGE_MAP_PATH = (
    Path(__file__).resolve().parents[2] / "config" / "lineage_map.yaml"
)


def load_lineage_map(path: Path | None = None) -> dict[str, str]:
    """Return ontology_term_id -> lineage display name from YAML.

    Raises:
        FileNotFoundError: if the map file is missing.
        ValueError: if required keys are absent or lineages are inconsistent.
    """
    map_path = path if path is not None else DEFAULT_LINEAGE_MAP_PATH
    if not map_path.is_file():
        raise FileNotFoundError(f"lineage map not found: {map_path}")

    with map_path.open() as handle:
        payload = yaml.safe_load(handle)

    if not isinstance(payload, dict):
        raise ValueError(f"lineage map must be a mapping: {map_path}")

    allowed = payload.get("lineages")
    term_to_lineage = payload.get("cell_type_ontology_term_id_to_lineage")
    if not isinstance(allowed, list) or not allowed:
        raise ValueError("lineage map requires a non-empty lineages list")
    if not isinstance(term_to_lineage, dict) or not term_to_lineage:
        raise ValueError(
            "lineage map requires cell_type_ontology_term_id_to_lineage"
        )

    allowed_set = set(allowed)
    for term_id, lineage in term_to_lineage.items():
        if lineage not in allowed_set:
            raise ValueError(
                f"term {term_id!r} maps to unknown lineage {lineage!r}; "
                f"allowed={sorted(allowed_set)}"
            )

    return {str(k): str(v) for k, v in term_to_lineage.items()}


def map_cell_types_to_lineage(
    cell_type_ontology_term_ids: Mapping[str, object] | list[str],
    term_to_lineage: Mapping[str, str],
) -> list[str]:
    """Map each ontology term id to a lineage; raise on any unmapped term.

    Unmapped terms are an invariant failure for this atlas: the Global object
    has a closed set of labels, and silent collapse into Everything else would
    hide annotation drift after a Census refresh.
    """
    if isinstance(cell_type_ontology_term_ids, Mapping):
        term_ids = [str(v) for v in cell_type_ontology_term_ids.values()]
    else:
        term_ids = [str(v) for v in cell_type_ontology_term_ids]

    unmapped = sorted({t for t in term_ids if t not in term_to_lineage})
    if unmapped:
        raise ValueError(
            "unmapped cell_type_ontology_term_id values "
            f"(update config/lineage_map.yaml): {unmapped}"
        )
    return [term_to_lineage[t] for t in term_ids]


def lineage_for_term(
    cell_type_ontology_term_id: str,
    term_to_lineage: Mapping[str, str],
) -> str:
    """Return the lineage for one ontology term id or raise."""
    term = str(cell_type_ontology_term_id)
    if term not in term_to_lineage:
        raise ValueError(
            f"unmapped cell_type_ontology_term_id: {term!r}; "
            "update config/lineage_map.yaml"
        )
    return term_to_lineage[term]

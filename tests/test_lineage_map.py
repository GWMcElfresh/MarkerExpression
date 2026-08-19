"""Unit tests for the closed Domínguez Conde Global lineage map."""

from __future__ import annotations

from pathlib import Path

import pytest

from analysis.lib.lineage_map import (
    lineage_for_term,
    load_lineage_map,
    map_cell_types_to_lineage,
)

# Every cell_type_ontology_term_id listed on the Global dataset in the
# CELLxGENE curation API for collection 62ef75e4-cbea-454e-a0ce-998ec40223d3.
GLOBAL_CELL_TYPE_ONTOLOGY_TERM_IDS = [
    "CL:0000938",
    "CL:0000939",
    "CL:0000492",
    "CL:0000909",
    "CL:0001203",
    "CL:0002038",
    "CL:0000789",
    "CL:0000583",
    "CL:0000860",
    "CL:0000990",
    "CL:0001056",
    "CL:0000905",
    "CL:0001062",
    "CL:0000764",
    "CL:0000798",
    "CL:0000844",
    "CL:0001071",
    "CL:0000542",
    "CL:0000235",
    "CL:0000097",
    "CL:0000556",
    "CL:0000787",
    "CL:0000940",
    "CL:0000788",
    "CL:0000895",
    "CL:0000900",
    "CL:0000875",
    "CL:0000786",
    "CL:0000980",
    "CL:0000784",
    "CL:0000817",
    "CL:0000826",
    "CL:0011026",
    "CL:0000815",
    "unknown",
]

REPO_ROOT = Path(__file__).resolve().parents[1]
LINEAGE_MAP_PATH = REPO_ROOT / "config" / "lineage_map.yaml"


def test_every_global_term_is_mapped():
    term_to_lineage = load_lineage_map(LINEAGE_MAP_PATH)
    missing = [
        t for t in GLOBAL_CELL_TYPE_ONTOLOGY_TERM_IDS if t not in term_to_lineage
    ]
    assert missing == [], f"unmapped Global terms: {missing}"


def test_unspecified_alphabeta_t_is_not_non_alphabeta():
    term_to_lineage = load_lineage_map(LINEAGE_MAP_PATH)
    # Generic alpha-beta T cell must stay out of Non-Alpha_beta (gamma-delta + MAIT).
    assert (
        lineage_for_term("CL:0000789", term_to_lineage)
        == "Unspecified_Alpha_beta_T_Cells"
    )
    assert lineage_for_term("CL:0000798", term_to_lineage) == "Non-Alpha_beta_T_Cells"
    assert lineage_for_term("CL:0000940", term_to_lineage) == "Non-Alpha_beta_T_Cells"


def test_unmapped_term_raises():
    term_to_lineage = load_lineage_map(LINEAGE_MAP_PATH)
    with pytest.raises(ValueError, match="unmapped"):
        map_cell_types_to_lineage(["CL:9999999"], term_to_lineage)


def test_monocytes_and_macrophages_are_distinct():
    term_to_lineage = load_lineage_map(LINEAGE_MAP_PATH)
    assert lineage_for_term("CL:0000860", term_to_lineage) == "Monocytes"
    assert lineage_for_term("CL:0000875", term_to_lineage) == "Monocytes"
    assert lineage_for_term("CL:0000235", term_to_lineage) == "Macrophages"
    assert lineage_for_term("CL:0000583", term_to_lineage) == "Macrophages"


def test_nk_cells_are_their_own_class():
    term_to_lineage = load_lineage_map(LINEAGE_MAP_PATH)
    assert lineage_for_term("CL:0000938", term_to_lineage) == "NK_cells"
    assert lineage_for_term("CL:0000939", term_to_lineage) == "NK_cells"


def test_tregs_are_not_cd4_t():
    term_to_lineage = load_lineage_map(LINEAGE_MAP_PATH)
    assert lineage_for_term("CL:0000815", term_to_lineage) == "Tregs"
    assert lineage_for_term("CL:0000492", term_to_lineage) == "CD4+_T_Cells"


def test_pro_pre_b_are_not_mature_b():
    term_to_lineage = load_lineage_map(LINEAGE_MAP_PATH)
    assert lineage_for_term("CL:0000817", term_to_lineage) == "Pro_pre_B_cells"
    assert lineage_for_term("CL:0000826", term_to_lineage) == "Pro_pre_B_cells"
    assert lineage_for_term("CL:0000788", term_to_lineage) == "B_cells"


def test_generic_progenitor_is_its_own_class():
    term_to_lineage = load_lineage_map(LINEAGE_MAP_PATH)
    assert lineage_for_term("CL:0011026", term_to_lineage) == "Progenitor_cells"


def test_lineage_names_use_underscore_delimiters():
    term_to_lineage = load_lineage_map(LINEAGE_MAP_PATH)
    for lineage in set(term_to_lineage.values()):
        assert " " not in lineage, lineage
        assert "/" not in lineage, lineage
        # Hyphens are only Non- (negation) or CD*- (marker-negative).
        for part in lineage.split("_"):
            if "-" not in part:
                continue
            assert part.startswith("Non-") or (
                part.startswith("CD") and part.endswith("-")
            ), lineage

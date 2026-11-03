# Maritime Zone Name Standardisation

## Overview

PostgreSQL SQL script that standardises maritime zone names in `geospatial.zones` using a geographic-aware title case logic.

The process produces a read-only preview of proposed name changes without modifying the original zone data. This logic easily be transferred to an mview, permanent table or to new columns in the zones table upon request.

## Key functionality

- **Title case:** Standardises capitalisation while respecting international geographic naming conventions.
- **Character cleaning:** Removes diacritics, unwanted characters and excess whitespace while preserving apostrophes.
- **Abbreviations:** Preserves recognised maritime acronyms (FPSO, SBM, TSS), geographical abbreviations and Roman numerals.
- **Facility identifiers:** Preserves alphanumeric codes such as `SB-1` and recognised mixed-case berth names such as `SVI Berth 1`.
- **Geographic context:** Uses `sandbox.zone_geography_enriched` to distinguish regional abbreviations from ordinary words.
- **Known corrections:** Corrects existing naming errors without automatically adding missing zone-type descriptors.
- **Short names:** Generates original and formatted short names capped at 30 characters.
- **Auditing:** Provides columns identifying applied rules, changed names and records requiring review.

## Requirements

PostgreSQL 13+, plus access to the existing `sandbox` schema and `geospatial.zones` table.

The executing account requires appropriate read and schema-level creation permissions. Validation additionally requires database `TEMP` permission.

## Files and execution

1. `zone_name_title_case_v2_3.sql` — Installs the formatter and preview views.

## Output

The results are currently available in:

`maritime_assets.sandbox.zone_name_title_case_preview_v2`

Primary columns:

| Column | Description |
|---|---|
| `fid` | Original zone identifier |
| `name` | Original full name |
| `name_formatted` | Standardised full name |
| `name_short` | Original name, capped at 30 characters |
| `name_short_formatted` | Formatted name, capped at 30 characters |

Additional audit columns identify applied rules, transformations and potential exceptions.

Only `Active` and `Active & curated` zones are processed. Missing geographic assignments do not exclude zones from formatting.

## Data safety
The solution does not modify geospatial.zones or the geographic source tables. All proposed name changes remain available for review and validation before any production implementation.

The solution does not modify `geospatial.zones` or the geographic source tables. All proposed name changes remain available for review and validation before any production implementation.

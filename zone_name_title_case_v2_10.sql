-- ============================================================================
-- ZONE NAME TITLE CASE / AUDITED PREVIEW v2.10
-- Run the ENTIRE script while connected to the intended maritime_assets database.
-- Uses the EXISTING sandbox schema. No schema creation, extensions, spatial
-- calculations, or production INSERT/UPDATE/DELETE statements are included.
--
-- Creates/replaces the v2 formatter, reusable vocabularies, rule catalogue
-- and preview views below.
-- Earlier naming views and sandbox.zone_geography_enriched remain untouched.
-- Requires PostgreSQL 13+ with UTF8, PL/pgSQL, SELECT on the inputs and CREATE in
-- sandbox. Run with stop-on-error enabled. Installation is one transaction.
--
-- Source mapping:
--   geospatial.zones.zone_id   -> fid (not a generated row number)
--   geospatial.zones.zone_name -> name
--   name_short = left(original zone_name,30) (no short column needed)
--   name_short_formatted = left(formatted full name,30).
-- Output: sandbox.zone_name_title_case_preview_v2
-- v2.5 added FLNG and FSU to the existing maritime uppercase list
-- (FSRU was already present), and introduced prescribed mixed-case forms
-- such as RoRo, RoPax, AtoN and MoU. Legal-form casing is contextual:
-- suffix/recognised post-company forms are corrected; ambiguous uppercase
-- prefixes such as APS are preserved and flagged rather than reinterpreted.
-- Retains v2.4 source-capitalisation safeguards and all prior geography rules.
-- v2.6: also preserves unknown intra-token camel/mixed case (PassNave,
-- beachB, BayWa) while letting exact dictionaries, ordinary geographic
-- words, compass words, and approved legal forms take precedence.
-- v2.7: preserve the source spelling of recognised multilingual connecting
-- words in already partly title-cased names (De, en, und, van, von, etc.).
-- Uppercase input still follows the original grammatical rules; a clear
-- de la / de le / de les phrase is lowercased before source-case protection.
-- Ambiguous capitalised De outside confirmed NL geography is reviewable.
-- v2.8: names containing a whole uppercase token alongside a whole
-- Titlecase token now retain intentional source casing, particularly for
-- ambiguous uppercase prefixes (OG South Berth, AM Seven Berth 1).
-- Only high-confidence dictionary, geographic and grammatical corrections
-- still apply; ALLCAPS-only names retain the original conversion path.
-- v2.9: preserve an existing standalone uppercase facility letter, especially
-- Terminal A and Pier P1 NS - A East/West; leave grammatical lowercase a
-- intact. Quoted Roman numerals such as II' also retain uppercase, while
-- the V2.9 identifier handling (No3 -> NO3) was unchanged then; V2.10 supersedes it.
--
-- v2.10: C.RO is a prescribed company/brand token with its dot retained.
-- Existing case variants (C.Ro, c.ro) become C.RO; unrelated CRO is not
-- reinterpreted as the brand. Exact No/NO + optional dot + integer is
-- normalised to No3/No.3 before alphanumeric identifier processing.
-- No additional maritime or company legal-form abbreviations are added.
--
-- Rule source: supplied Title Case - Rules List.csv, original ancillary SQL,
-- original zone-cleaning SQL, and the subsequent decisions in this conversation.
-- Standard regional-code sources:
-- https://pe.usps.com/text/pub28/pub28apb.htm
-- https://www.canadapost-postescanada.ca/cpc/en/support/articles/addressing-guidelines/symbols-and-abbreviations.page
-- https://www.stylemanual.gov.au/grammar-punctuation-and-conventions/names-and-terms/australian-place-names
-- Australian forms are uppercased here by the agreed project convention.
-- ============================================================================

BEGIN;
SET LOCAL standard_conforming_strings = on;

-- 1. Preflight verifies access to the existing sandbox schema and the two
-- source tables, and rejects duplicate zone IDs before installing any views.
DO $preflight$
BEGIN
    IF to_regnamespace('sandbox') IS NULL THEN
        RAISE EXCEPTION 'Required existing schema sandbox was not found. No schema will be created.';
    END IF;
    IF NOT has_schema_privilege(current_user, 'sandbox', 'USAGE')
       OR NOT has_schema_privilege(current_user, 'sandbox', 'CREATE') THEN
        RAISE EXCEPTION 'USAGE and CREATE on existing schema sandbox are required; database CREATE is not required.';
    END IF;
    IF current_setting('server_version_num')::integer < 130000
       OR current_setting('server_encoding') <> 'UTF8' THEN
        RAISE EXCEPTION 'This script requires PostgreSQL 13+ and UTF8 encoding.';
    END IF;
    IF to_regclass('geospatial.zones') IS NULL THEN
        RAISE EXCEPTION 'geospatial.zones was not found in database %.', current_database();
    END IF;
    IF to_regclass('sandbox.zone_geography_enriched') IS NULL THEN
        RAISE EXCEPTION 'sandbox.zone_geography_enriched was not found. Missing geography per row is supported; the input relation itself is required.';
    END IF;
    IF EXISTS (SELECT 1 FROM sandbox.zone_geography_enriched AS e
               GROUP BY e.zone_id HAVING count(*) > 1) THEN
        RAISE EXCEPTION 'Duplicate zone_id values in sandbox.zone_geography_enriched; resolve before installing to avoid duplicated output.';
    END IF;
    IF EXISTS (SELECT 1 FROM geospatial.zones AS z
               WHERE z.zone_check_status::text IN ('Active','Active & curated')
               GROUP BY z.zone_id HAVING count(*) > 1 OR z.zone_id IS NULL) THEN
        RAISE EXCEPTION 'Active source zone_id values must be non-NULL and unique.';
    END IF;
END;
$preflight$;

-- 2. Regional-code lookup contains the approved US, Canadian and Australian
-- state/province/territory abbreviations used for geographic context.
CREATE OR REPLACE FUNCTION sandbox.zntc_v2_region_codes(p_country_iso2 text)
RETURNS text[]
LANGUAGE sql IMMUTABLE PARALLEL SAFE
AS $codes$
    SELECT CASE upper(p_country_iso2)
      WHEN 'US' THEN ARRAY['AL','AK','AZ','AR','CA','CO','CT','DE','DC','FL','GA','HI','ID','IL','IN','IA','KS','KY','LA','ME','MD','MA','MI','MN','MS','MO','MT','NE','NV','NH','NJ','NM','NY','NC','ND','OH','OK','OR','PA','RI','SC','SD','TN','TX','UT','VT','VA','WA','WV','WI','WY']::text[]
      WHEN 'CA' THEN ARRAY['AB','BC','MB','NB','NL','NT','NS','NU','ON','PE','QC','SK','YT']::text[]
      WHEN 'AU' THEN ARRAY['ACT','NSW','NT','QLD','SA','TAS','VIC','WA']::text[]
      ELSE ARRAY[]::text[]
    END;
$codes$;

-- 3. This read-only reference view gives each code a human-readable region
-- name, supporting audit reports and checks against geographic enrichment.
CREATE OR REPLACE VIEW sandbox.zone_name_region_codes_v2 AS
SELECT r.country_iso2, r.regional_abbreviation, r.subdivision_name
FROM (VALUES
    ('US','AL','Alabama'),
    ('US','AK','Alaska'),
    ('US','AZ','Arizona'),
    ('US','AR','Arkansas'),
    ('US','CA','California'),
    ('US','CO','Colorado'),
    ('US','CT','Connecticut'),
    ('US','DE','Delaware'),
    ('US','DC','District of Columbia'),
    ('US','FL','Florida'),
    ('US','GA','Georgia'),
    ('US','HI','Hawaii'),
    ('US','ID','Idaho'),
    ('US','IL','Illinois'),
    ('US','IN','Indiana'),
    ('US','IA','Iowa'),
    ('US','KS','Kansas'),
    ('US','KY','Kentucky'),
    ('US','LA','Louisiana'),
    ('US','ME','Maine'),
    ('US','MD','Maryland'),
    ('US','MA','Massachusetts'),
    ('US','MI','Michigan'),
    ('US','MN','Minnesota'),
    ('US','MS','Mississippi'),
    ('US','MO','Missouri'),
    ('US','MT','Montana'),
    ('US','NE','Nebraska'),
    ('US','NV','Nevada'),
    ('US','NH','New Hampshire'),
    ('US','NJ','New Jersey'),
    ('US','NM','New Mexico'),
    ('US','NY','New York'),
    ('US','NC','North Carolina'),
    ('US','ND','North Dakota'),
    ('US','OH','Ohio'),
    ('US','OK','Oklahoma'),
    ('US','OR','Oregon'),
    ('US','PA','Pennsylvania'),
    ('US','RI','Rhode Island'),
    ('US','SC','South Carolina'),
    ('US','SD','South Dakota'),
    ('US','TN','Tennessee'),
    ('US','TX','Texas'),
    ('US','UT','Utah'),
    ('US','VT','Vermont'),
    ('US','VA','Virginia'),
    ('US','WA','Washington'),
    ('US','WV','West Virginia'),
    ('US','WI','Wisconsin'),
    ('US','WY','Wyoming'),
    ('CA','AB','Alberta'),
    ('CA','BC','British Columbia'),
    ('CA','MB','Manitoba'),
    ('CA','NB','New Brunswick'),
    ('CA','NL','Newfoundland and Labrador'),
    ('CA','NT','Northwest Territories'),
    ('CA','NS','Nova Scotia'),
    ('CA','NU','Nunavut'),
    ('CA','ON','Ontario'),
    ('CA','PE','Prince Edward Island'),
    ('CA','QC','Quebec'),
    ('CA','SK','Saskatchewan'),
    ('CA','YT','Yukon'),
    ('AU','ACT','Australian Capital Territory'),
    ('AU','NSW','New South Wales'),
    ('AU','NT','Northern Territory'),
    ('AU','QLD','Queensland'),
    ('AU','SA','South Australia'),
    ('AU','TAS','Tasmania'),
    ('AU','VIC','Victoria'),
    ('AU','WA','Western Australia')
) AS r(country_iso2, regional_abbreviation, subdivision_name);

-- 4. Geographical/structural vocabulary identifies ordinary words that
-- should be title-cased even when the input is uppercase.
-- The same immutable arrays are used by the formatter and inspection view.
CREATE OR REPLACE FUNCTION sandbox.zntc_v2_geographic_words()
RETURNS text[] LANGUAGE sql IMMUTABLE PARALLEL SAFE
AS $geo_words$
    SELECT ARRAY[
        'SEA','SEAS','BAY','BAYS','OCEAN','GULF','STRAIT','STRAITS',
        'SOUND','CHANNEL','CHANNELS','RIVER','RIVERS','ISLAND','ISLANDS',
        'ISLE','ISLES','ISLET','ISLETS','HARBOUR','HARBOR','HARBOURS',
        'HARBORS','PORT','PORTS','BERTH','BERTHS','BERTHING','TERMINAL',
        'TERMINALS','ANCHORAGE','ANCHORAGES','QUAY','QUAYS','PIER','PIERS',
        'DOCK','DOCKS','SHIPYARD','SHIPYARDS','MARINA','MARINAS',
        'WHARF','WHARVES','JETTY','JETTIES','BASIN','BASINS',
        'APPROACH','APPROACHES','OFFSHORE','NORTH','SOUTH','EAST','WEST',
        'NORTHEAST','NORTHWEST','SOUTHEAST','SOUTHWEST','NORTHBOUND',
        'SOUTHBOUND','EASTBOUND','WESTBOUND','NORTHERN','SOUTHERN',
        'EASTERN','WESTERN','DRY','FLOATING','SLIPWAY','SLIPWAYS',
        'OIL','GAS','YARD','YARDS','PLANT','CANAL','CANALS','CITY',
        'NEW','OLD','MAIN','INNER','OUTER','UPPER','LOWER','COAST','COASTAL',
        'STATION','FIELD','FIELDS','WAITING','AREA','AREAS','WATERS',
        'MOUTH','CREEK','POINT','REEF','CAPE','HEAD','HEADLAND',
        'SHOAL','SHOALS','BANK','BANKS','FERRY','CONTAINER','CARGO',
        'BULK','TANKER','PASSENGER','MOORING','MOORINGS','BUOY',
        'PLATFORM','PLATFORMS','FACILITY','FACILITIES','BUNKERING'
    ]::text[];
$geo_words$;

-- 5. Established, widely used maritime abbreviations retain uppercase;
-- operator- and terminal-specific prefixes are deliberately not listed here.
CREATE OR REPLACE FUNCTION sandbox.zntc_v2_maritime_acronyms()
RETURNS text[] LANGUAGE sql IMMUTABLE PARALLEL SAFE
AS $maritime$
    SELECT ARRAY[
        'IMMA','ECA','TSS','NM','MARPOL','MW','OWF','SRR','MICT',
        'UKMTO','UTAG','OT','OSI','FPSO','FPS','FSO','STS','SBM',
        'SPM','MBM','CBM','OPL','SWO','LNG','LPG','IMO','AIS','VTS',
        'FSRU','FLNG','FSU','EPO'
    ]::text[];
$maritime$;

-- 5a. Exact prescribed spellings are distinct from uppercase acronyms.
-- Legal forms require position/context in the formatter; this dictionary
-- alone does not assert that an ambiguous token is a company suffix.
CREATE OR REPLACE FUNCTION sandbox.zntc_v2_prescribed_casing()
RETURNS TABLE (recognition_key text, canonical_form text, category text, context_policy text)
LANGUAGE sql IMMUTABLE PARALLEL SAFE
AS $prescribed$
    SELECT x.recognition_key,x.canonical_form,x.category,x.context_policy
    FROM (VALUES
        ('RORO','RoRo','maritime_mixed_case','anywhere'),
        ('RO-RO','Ro-Ro','maritime_mixed_case','exact_hyphenated_phrase'),
        ('ROPAX','RoPax','maritime_mixed_case','anywhere'),
        ('ATON','AtoN','maritime_mixed_case','anywhere'),
        ('MOU','MoU','maritime_mixed_case','anywhere'),
        ('C.RO','C.RO','company_brand','exact_dotted_token_anywhere'),
        ('GMBH','GmbH','company_legal_form','suffix_or_before_facility_or_already_correct'),
        ('GGMBH','gGmbH','company_legal_form','suffix_or_before_facility_or_already_correct'),
        ('APS','ApS','company_legal_form','suffix_or_before_facility_or_already_correct'),
        ('SRL','S.r.l.','company_legal_form','dotted_suffix_or_before_facility'),
        ('SPA','S.p.A.','company_legal_form','dotted_suffix_or_before_facility'),
        ('SRO','s.r.o.','company_legal_form','dotted_suffix_or_before_facility'),
        ('DOO','d.o.o.','company_legal_form','dotted_suffix_or_before_facility'),
        ('SP_Z_OO','sp. z o.o.','company_legal_form','dotted_phrase_suffix_or_before_facility'),
        ('PTE_LTD','Pte. Ltd.','company_legal_form','dotted_phrase_suffix_or_before_facility'),
        ('SDN_BHD','Sdn. Bhd.','company_legal_form','dotted_phrase_suffix_or_before_facility'),
        ('SA_RL','S.a r.l.','company_legal_form','dotted_phrase_after_diacritic_removal'),
        ('AG','AG','company_legal_form','suffix_only'),
        ('BV','BV','company_legal_form','suffix_only'),
        ('NV','NV','company_legal_form','suffix_only'),
        ('LLC','LLC','company_legal_form','suffix_only'),
        ('LLP','LLP','company_legal_form','suffix_only'),
        ('PLC','PLC','company_legal_form','suffix_only')
    ) AS x(recognition_key,canonical_form,category,context_policy);
$prescribed$;

-- 5b. Browse this view to review legal forms and exact maritime spellings.
-- It does not change or populate any source table.
CREATE OR REPLACE VIEW sandbox.zone_name_prescribed_casing_v2 AS
SELECT recognition_key,canonical_form,category,context_policy
FROM sandbox.zntc_v2_prescribed_casing();

-- 6. This view exposes both vocabularies for inspection in DBeaver; it
-- does not add any records to the source zone tables.
CREATE OR REPLACE VIEW sandbox.zone_name_vocabulary_v2 AS
SELECT 'geographical_or_structural_word'::text AS category, g.token
FROM unnest(sandbox.zntc_v2_geographic_words()) AS g(token)
UNION ALL
SELECT 'established_maritime_abbreviation'::text AS category, a.token
FROM unnest(sandbox.zntc_v2_maritime_acronyms()) AS a(token);

-- 7. The rule catalogue explains every audit label used by the formatter.
-- It includes the new whole-name preservation rule with its strict scope.
CREATE OR REPLACE VIEW sandbox.zone_name_rule_catalog_v2 AS
SELECT r.rule_key, r.specification_reference, r.description
FROM (VALUES
    ('unicode_normalised','CLEAN','Canonical Unicode normalisation, including decomposed accented letters.'),
    ('diacritics_removed','CLEAN','Original intended accent mapping plus case-paired ligatures; not a general transliterator.'),
    ('apostrophes_normalised','CLEAN','Curly/typographical or known broken-encoding apostrophes made straight.'),
    ('dashes_normalised','CLEAN','En/em/nonbreaking dashes and minus signs converted to hyphens.'),
    ('backslashes_to_hyphens','CLEAN','Backslashes converted to hyphens.'),
    ('underscores_to_spaces','CLEAN','Underscores replaced by spaces.'),
    ('plus_to_ampersand','CLEAN','Original conditional plus-to-ampersand substitution.'),
    ('commas_removed','CLEAN','Commas replaced with spaces; no inverted-name rearrangement.'),
    ('unwanted_symbols_removed','CLEAN','Selected clutter replaced by spaces; apostrophes, periods, slashes, parentheses and ampersands retained.'),
    ('whitespace_normalised','CLEAN','Repeated whitespace collapsed and ends trimmed.'),
    ('anch_expanded','CORRECTION','Existing ANCH/ANCH. expanded only for Anchorage zones.'),
    ('drydock_corrected','CORRECTION','Existing DRYDOCK/DRYDOCKS split into Dry Dock/Dry Docks.'),
    ('leading_number_reordered','CORRECTION','Whole number-plus-descriptor name reversed only for a compatible zone type.'),
    ('title_case','RULE-02/RULE-08','Default major-word title case; not part-of-speech or name-entity recognition.'),
    ('first_last_word','RULE-01','First/last lexical token capitalisation, below explicit exceptions in precedence.'),
    ('minor_words','RULE-03','Internal English minor words and explicitly listed foreign particles lowercased; a separate source-case rule can preserve already formatted multilingual particles.'),
    ('proper_name_exceptions','RULE-03(F)','De Haandrik/De Bilt/De Ree/The Netherlands.'),
    ('language_context_exceptions','ANCILLARY','Recognised Slovenian v, Ong Do and wa adh contexts.'),
    ('hyphenation','RULE-04','Hyphen-connected components formatted independently.'),
    ('apostrophe_casing','RULE-05/RULE-05(B)','Elisions versus possessives/internal phonetic apostrophes.'),
    ('acronyms','RULE-06','Explicit maritime/country acronym whitelist; dotted forms recognised.'),
    ('geographic_word_recognised','VOCABULARY','Recognised ordinary geographic/structural word, including word-number forms such as SEA1; title case wins over numeric-code preservation.'),
    ('maritime_abbreviation_preserved','VOCABULARY','Recognised established maritime acronym; separate audit from generic acronym protection.'),
    ('alphanumeric_identifier_preserved','IDENTIFIER','Short alphanumeric or letter-hyphen-number identifiers such as SB1, SB-1 and PL-4; does not imply a known company acronym.'),
    ('acronym_review_candidate','REVIEW','Potential unknown facility/terminal acronym; report only, never automatically preserve.'),
    ('mixed_case_berth_pattern_preserved','FACILITY_PATTERN','Verbatim preservation of an exact uppercase 2-6 letter prefix + Berth + number for Berth/Shipyard Berth types; ordinary geographic words are excluded.'),
    ('mixed_case_uppercase_token_preserved','MIXED_CASE','Preserve an existing 2-8 letter uppercase standalone token in otherwise title-cased input, except ordinary geographical words and grammatical particles without facility context.'),
    ('mixed_case_internal_acronym_preserved','MIXED_CASE','Preserve an original intra-word acronym that mixes lowercase with consecutive uppercase letters, such as DGzRS; ordinary compass words remain formatted.'),
    ('internal_mixed_case_preserved','MIXED_CASE','Protect an unknown alphabetic word with a lowercase-to-uppercase transition (PassNave, beachB, BayWa). Exact spellings and recognised ordinary words/compass compounds take priority; older DGzRS protection also receives this audit tag.'),
    ('multilingual_particle_case_preserved','MULTILINGUAL','Preserve originally lower/title-cased foreign conjunctions, articles and particles in otherwise partly title-cased names; uppercase and established exceptions still follow existing rules.'),
    ('existing_mixed_case_name_preserved','SOURCE_CASE','A name with separate uppercase and Titlecase words retains unrecognised source token casing; verified terminology, geographical words and grammatical exceptions still take precedence. This is not an ALLCAPS exemption.'),
    ('single_letter_connector_preserved','IDENTIFIER','Uppercase both letters of A&B or A-B style one-letter connectors (including V&a converted to V&A).'),
    ('single_letter_facility_identifier_preserved','IDENTIFIER','Preserve an existing uppercase A-Z facility label after a facility descriptor or in a coded pier direction pattern. Port A is ambiguous and flagged for review.'),
    ('allcaps_acronym_candidate','REVIEW','All-uppercase unknown short prefix near a facility descriptor, number, or letter: proposed title case, flagged for dictionary review.'),
    ('prescribed_maritime_capitalisation','PRESCRIBED','Use exact RoRo, Ro-Ro, RoPax, AtoN or MoU spelling instead of all-uppercase/title-case.'),
    ('company_legal_form_prescribed','LEGAL_FORM','Use approved case for a legal-form suffix or confirmed existing legal-case spelling, including recognised dotted multiword forms.'),
    ('company_brand_prescribed','BRAND','Recognise the exact dotted company name C.RO irrespective of original casing; leave undotted CRO and other words unchanged.'),
    ('number_followed_by_digits_standardised','NUMBER','Convert whole tokens No3/NO3/NO.3/no.12 to canonical No3/No.3 while preserving an existing dot, before generic alphanumeric rules.'),
    ('ambiguous_company_prefix_preserved','REVIEW','Preserve originally uppercase APS/GMBH/gGmbH in prefix position; do not infer a company suffix.'),
    ('geographic_abbreviations','GEOGRAPHY','Contextual country or regional code, or conservative unconfirmed unambiguous suffix.'),
    ('ambiguous_geographic_code_preserved','REVIEW','Uncertain suffix keeps its input spelling; not counted as confirmed geography.'),
    ('compass_compounds','RULE-07','Fused compass words lose internal camel-casing.'),
    ('roman_numerals','RULE-09','Valid Roman numeral tokens I to XXXIX, including immediately before a closing apostrophe/quotation mark; grammatical v contexts take priority.'),
    ('foreign_suffix_exceptions','RULE-04(B)/RULE-10','Whole recognised phrases only; never a blanket lowercase -E/-Do/-Gun rule.'),
    ('identifiers','IDENTIFIER','Explicit hyphenated identifiers, letter ranges and short alphanumeric labels.'),
    ('number_abbreviation','ABBREVIATION','No before a number or with its abbreviation period; not Norway NO.'),
    ('standard_abbreviations','RULE-06','St., Appr. and Co. stay standard title-style contractions.'),
    ('units','ANCILLARY','Attached integer or decimal MW/NM units retain uppercase.'),
    ('ordinals','IDENTIFIER','Numeric ordinal suffixes retain lowercase, e.g. 21st.')
) AS r(rule_key, specification_reference, description);

-- 8. The formatter handles cleaning, contextual title case and an ordered
-- audit of each rule; it returns text only and never updates source data.
CREATE OR REPLACE FUNCTION sandbox.zntc_v2_format(
    p_name text,
    p_zone_type text,
    p_country_iso2 text DEFAULT NULL,
    p_regional_abbreviation text DEFAULT NULL,
    p_country_context_ok boolean DEFAULT false,
    p_region_context_ok boolean DEFAULT false
)
RETURNS TABLE (
    cleaned_name text,
    corrected_name text,
    reordered_name text,
    formatted_name text,
    rules_applied text[],
    rules_changed text[],
    rule_audit jsonb,
    review_reasons text[],
    roman_numerals text[],
    acronyms text[],
    geographic_abbreviations text[]
)
LANGUAGE plpgsql IMMUTABLE PARALLEL SAFE
SET search_path = pg_catalog, pg_temp
AS $format$
DECLARE
    v_s text := p_name;
    v_before_step text;
    v_step text;
    v_rule text;
    v_type text := lower(coalesce(p_zone_type,''));
    v_country text := upper(nullif(btrim(p_country_iso2),''));
    v_region text := upper(nullif(btrim(p_regional_abbreviation),''));
    v_country_ok boolean;
    v_region_ok boolean;
    v_region_codes text[];
    v_all_regions text[];
    v_ambiguous text[] := ARRAY[
        'AL','AR','AZ','CA','CO','DE','HI','ID','IN','LA','MA','ME',
        'NE','OH','OK','ON','OR','PA','SA','VA','WA','ACT','VIC','AU','NO','BE','DO'
    ];
    v_minors text[] := ARRAY[
        'a','an','the','and','or','for','on','in','at','to','by','of','from',
        'de','del','dell','der','di','du','da','des','dos','la','og','ob','do',
        'al','az','va','van','von','y','pri','ash','na','aux','am','ad','ech',
        'kai','sur','os','au','en','und'
    ];
    -- v2.7: trust existing lowercase/Titlecase foreign connecting words in
    -- names that already contain normal title-cased words. Unlike v_minors,
    -- this excludes English glue words to avoid freezing casing mistakes.
    v_multilingual_particles text[] := ARRAY[
        'de','del','dell','der','di','du','da','des','dos','la',
        'og','ob','do','al','az','va','van','von','y','pri',
        'ash','na','aux','am','ad','ech','kai','sur','os','au',
        'en','und'
    ];
    -- v2.8: only these clearly grammatical uppercase connectors are
    -- re-cased inside mixed names; ambiguous OG, AM, VA, etc. stay source
    -- uppercase unless a stronger confirmed dictionary rule wins.
    v_clear_grammar_upper text[] := ARRAY[
        'AND','OR','THE','OF','FOR','TO','BY','FROM',
        'DE','DEL','DES','EN','UND','VAN','VON','DER','DI','DU','DA','DOS','LA'
    ];
    v_acronyms text[];
    v_maritime_acronyms text[];
    v_geographic_words text[];
    -- Cache the prescribed dictionary once per name rather than querying
    -- reference rows for every token; the ordering of both arrays agrees.
    v_prescribed_keys text[];
    v_prescribed_forms text[];
    v_prescribed_categories text[];
    v_prescribed_idx integer;
    v_legal_token_outputs text[];
    v_legal_context boolean;
    v_legal_base text;
    v_legal_current_is_dotted boolean;
    v_ro_ro_token boolean;
    v_preceding_company_word boolean;
    v_following_facility boolean;
    v_legal_phrase text;
    v_phrase_chunks text[];
    -- Facility terms used ONLY to identify candidates for human review.
    v_facility_terms text[] := ARRAY[
        'BERTH','BERTHS','BERTHING','TERMINAL','TERMINALS','DOCK',
        'DOCKS','JETTY','PIER','QUAY','WHARF','SHIPYARD','MARINA',
        'ANCHORAGE','MOORING','SLIPWAY','PLATFORM'
    ];
    v_country_labels text[] := ARRAY['USA','US','UK','GB','AU','NZ','CA','NO'];
    v_events jsonb := '[]'::jsonb;
    v_review text[] := ARRAY[]::text[];
    v_romans text[] := ARRAY[]::text[];
    v_acronym_matches text[] := ARRAY[]::text[];
    v_geographic_matches text[] := ARRAY[]::text[];
    v_tokens text[] := ARRAY[]::text[];
    v_separators text[] := ARRAY[]::text[];
    v_buffer text := '';
    v_tail text;
    v_token text;
    v_new text;
    v_upper text;
    v_lower text;
    v_lookup text;
    v_prev text;
    v_next text;
    v_next_upper text;
    v_after text;
    v_is_hyphen boolean;
    v_is_standalone boolean;
    v_suffix boolean;
    v_parenthesised boolean;
    v_geo_candidate boolean;
    v_protected_identifier boolean;
    v_structured_identifier boolean;
    v_geographic_word boolean;
    v_is_maritime_acronym boolean;
    v_mixed_case_source boolean;
    v_allcaps_source boolean;
    v_existing_mixed_name boolean := false;
    v_has_uppercase_word boolean := false;
    v_has_titlecase_word boolean := false;
    v_preserve_mixed_upper boolean;
    v_preserve_internal_mixed boolean;
    v_preserve_inner_case boolean;
    v_preserve_multilingual_particle boolean;
    v_single_letter_connector boolean;
    v_single_letter_facility_identifier boolean;
    v_candidate_reason text;
    v_inverted boolean := false;
    v_n integer;
    v_i integer;
    v_j integer;
    v_k integer;
    v_arr text[];
    v_descriptor text;
    v_parts text[];
    v_prefix text;
    v_result text := '';
    v_rec record;
    v_preserve_match text[];
BEGIN
    -- NULL input names remain NULL. A NULL full name is flagged by the view.
    rules_applied := ARRAY[]::text[];
    rules_changed := ARRAY[]::text[];
    rule_audit := '[]'::jsonb;
    review_reasons := ARRAY[]::text[];
    roman_numerals := ARRAY[]::text[];
    acronyms := ARRAY[]::text[];
    geographic_abbreviations := ARRAY[]::text[];
    IF p_name IS NULL THEN
        RETURN NEXT;
        RETURN;
    END IF;

    v_geographic_words := sandbox.zntc_v2_geographic_words();
    -- A source with a genuine Titlecase-looking word supplies stronger evidence
    -- that neighbouring uppercase tokens were intentional. ALLCAPS does not.
    v_mixed_case_source := p_name ~ '[A-Z][a-z]';
    v_allcaps_source := p_name = upper(p_name) AND p_name ~ '[A-Z]';

    -- 8a. Preserve ONLY an exact already-formatted berth pattern, such as
    -- 'SVI Berth 1': 2-6 uppercase letters, ' Berth ', then digits/optional A-Z.
    -- Restrict to berth zone types and exclude ordinary words like NORTH/MAIN.
    -- No cleaning, case conversion or number repositioning occurs on a match.
    IF v_type IN ('berth','shipyard berth') THEN
        v_preserve_match := regexp_match(
            p_name, '^([A-Z]{2,6}) Berth ([0-9]+[A-Z]?)$'
        );
    END IF;
    IF v_preserve_match IS NOT NULL
       AND NOT (v_preserve_match[1] = ANY(v_geographic_words)) THEN
        cleaned_name := p_name;
        corrected_name := p_name;
        reordered_name := p_name;
        formatted_name := p_name;
        rules_applied := ARRAY['mixed_case_berth_pattern_preserved']::text[];
        rules_changed := ARRAY[]::text[];
        rule_audit := jsonb_build_array(jsonb_build_object(
            'rule','mixed_case_berth_pattern_preserved',
            'before',p_name,'after',p_name,'changed',false,
            'kind','preserve_only',
            'reason','already_formatted_uppercase_prefix_berth_number'
        ));
        RETURN NEXT;
        RETURN;
    END IF;

    -- 8b. Unmatched names retain the earlier cleaning/geographic rules, with
    -- additional whole-token preservation for deliberately mixed-case inputs.
    v_maritime_acronyms := sandbox.zntc_v2_maritime_acronyms();
    -- Cache canonical forms and recognition keys for prescribed case.
    -- All lookups are case-insensitive, but the output comes from the dictionary.
    SELECT array_agg(d.recognition_key ORDER BY d.recognition_key),
           array_agg(d.canonical_form ORDER BY d.recognition_key),
           array_agg(d.category ORDER BY d.recognition_key)
    INTO v_prescribed_keys,v_prescribed_forms,v_prescribed_categories
    FROM sandbox.zntc_v2_prescribed_casing() AS d;
    -- Existing non-maritime acronym whitelist remains unchanged; e.g. UK/US.
    v_acronyms := v_maritime_acronyms || ARRAY[
        'USA','US','UK','NZ','BBC','EH','FA'
    ]::text[];
    v_region_codes := sandbox.zntc_v2_region_codes(v_country);
    v_all_regions := sandbox.zntc_v2_region_codes('US')
                  || sandbox.zntc_v2_region_codes('CA')
                  || sandbox.zntc_v2_region_codes('AU');
    v_country_ok := coalesce(p_country_context_ok,false)
                    AND coalesce(v_country ~ '^[A-Z]{2}$',false);
    v_region_ok := v_country_ok AND coalesce(p_region_context_ok,false)
                   AND coalesce(v_region = ANY(v_region_codes),false);

    -- 8c. Clean accents, apostrophes, symbols and spacing sequentially.
    -- Each step that changes text is recorded in the JSON rule audit.
    FOREACH v_step IN ARRAY ARRAY[
        'unicode_normalised','apostrophes_normalised','diacritics_removed',
        'dashes_normalised','backslashes_to_hyphens','underscores_to_spaces',
        'plus_to_ampersand','commas_removed','unwanted_symbols_removed',
        'whitespace_normalised'
    ] LOOP
        v_before_step := v_s;
        CASE v_step
          WHEN 'unicode_normalised' THEN
            v_s := normalize(v_s, NFC);
          WHEN 'diacritics_removed' THEN
            v_s := translate(v_s, 'ÁÀÂÄÃĀÅáàâäãāåÇČĆçčćÉÈÊËĘéèêëęÍÌÎÏíìîïÑñÓÒÔÖÕØóòôöõøŞŠşšÚÙÛÜúùûüÝŸýÿ', 'AAAAAAAaaaaaaaCCCcccEEEEEeeeeeIIIIiiiiNnOOOOOOooooooSSssUUUUuuuuYYyy');
            v_s := replace(replace(replace(replace(v_s,
                U&'\00c6','AE'), U&'\00e6','ae'), U&'\00df','ss'), U&'\1e9e','SS');
          WHEN 'apostrophes_normalised' THEN
            v_s := replace(replace(v_s,U&'\00e2\20ac\2122',chr(39)),
                                            U&'\00e2\20ac\02dc',chr(39));
            v_s := translate(v_s,U&'\2019\2018\02bc\02bb\ff07\00b4\02b9',repeat(chr(39),7));
            v_s := replace(v_s,chr(96),chr(39));
          WHEN 'dashes_normalised' THEN
            v_s := translate(v_s,U&'\2013\2014\2212\2011','----');
          WHEN 'backslashes_to_hyphens' THEN
            v_s := replace(v_s,chr(92),'-');
          WHEN 'underscores_to_spaces' THEN
            v_s := replace(v_s,'_',' ');
          WHEN 'plus_to_ampersand' THEN
            -- Intentionally preserves the original whitespace conditions.
            v_s := regexp_replace(v_s,'(?<=\S)\+(?=\S)|(?<=\s)\+(?=\s)','&','g');
          WHEN 'commas_removed' THEN
            v_s := regexp_replace(v_s,U&'[,\ff0c\060c]+',' ','g');
          WHEN 'unwanted_symbols_removed' THEN
            v_s := translate(v_s,'*^%${}[]<>~|#?"',repeat(' ',16));
            v_s := regexp_replace(v_s,U&'[;:\061b\00b7\2022\0387]+',' ','g');
            v_s := replace(v_s,U&'\ff0e','.');
          WHEN 'whitespace_normalised' THEN
            v_s := replace(replace(v_s,chr(160),' '),chr(8203),' ');
            v_s := btrim(regexp_replace(v_s,'[[:space:]]+',' ','g'));
        END CASE;
        IF v_before_step IS DISTINCT FROM v_s THEN
            v_events := v_events || jsonb_build_array(jsonb_build_object(
                'rule',v_step,'before',v_before_step,'after',v_s,'changed',true));
        END IF;
    END LOOP;
    cleaned_name := v_s;

    IF p_name ~* '[,:][[:space:]]*(principality|principado|region|republic|kingdom|province)[[:space:]]+(of|de)$' THEN
        v_inverted := true;
        v_review := array_append(v_review,'possible_inverted_name_not_rearranged');
    END IF;
    IF position('+' in v_s) > 0 THEN
        v_review := array_append(v_review,'plus_sign_not_converted_by_original_conditions');
    END IF;
    IF octet_length(v_s) > length(v_s) THEN
        v_review := array_append(v_review,'non_ascii_remains_after_original_transliteration');
    END IF;

    -- 8d. Correct existing ANCH and DRYDOCK text where applicable.
    -- This never invents a missing zone-type descriptor.
    v_before_step := v_s;
    IF v_type = 'anchorage' THEN
        v_s := regexp_replace(v_s,'\mANCH\M\.?','Anchorage','gi');
    END IF;
    IF v_s IS DISTINCT FROM v_before_step THEN
        v_events := v_events || jsonb_build_array(jsonb_build_object(
            'rule','anch_expanded','before',v_before_step,'after',v_s,'changed',true));
    END IF;
    v_before_step := v_s;
    v_s := regexp_replace(v_s,'\mDRYDOCK(S?)\M','Dry Dock\1','gi');
    IF v_s IS DISTINCT FROM v_before_step THEN
        v_events := v_events || jsonb_build_array(jsonb_build_object(
            'rule','drydock_corrected','before',v_before_step,'after',v_s,'changed',true));
    END IF;
    corrected_name := v_s;

    -- 8e. Reorder an entire number-plus-existing-descriptor name only
    -- when both the pattern and the zone type make the change unambiguous.
    v_descriptor := CASE v_type
        WHEN 'berth' THEN 'BERTH'
        WHEN 'shipyard berth' THEN '(?:SHIPYARD[[:space:]]+)?BERTH'
        WHEN 'dry dock' THEN 'DRY[[:space:]]+DOCK'
        WHEN 'floating dock' THEN 'FLOATING[[:space:]]+DOCK'
        WHEN 'slipway' THEN 'SLIPWAY'
        WHEN 'shipyard' THEN 'SHIPYARD'
        ELSE NULL END;
    IF v_descriptor IS NOT NULL THEN
        v_arr := regexp_match(v_s,'^([0-9]+[A-Z]?)[[:space:]]+(' || v_descriptor || ')$','i');
        IF v_arr IS NOT NULL THEN
            v_before_step := v_s;
            v_s := v_arr[2] || ' ' || upper(v_arr[1]);
            v_events := v_events || jsonb_build_array(jsonb_build_object(
                'rule','leading_number_reordered','before',v_before_step,'after',v_s,'changed',true));
        ELSIF v_s ~ '^[0-9]+[A-Za-z]?[[:space:]]+'
              AND v_s ~* ('\m' || v_descriptor || '\M') THEN
            v_review := array_append(v_review,'complex_leading_number_not_reordered');
        END IF;
    END IF;
    reordered_name := v_s;

    -- 8f. Tokenise while retaining punctuation separators and apostrophes.
    -- This prevents parts of names like d'Or being mistaken for state codes.
    FOR v_rec IN
        SELECT m.parts
        FROM regexp_matches(v_s,
            $rx$([[:alnum:]]+(?:[.'][[:alnum:]]+)*'?)|([^[:alnum:]]+)$rx$,
            'g') WITH ORDINALITY AS m(parts,ord)
        ORDER BY m.ord
    LOOP
        IF v_rec.parts[1] IS NOT NULL THEN
            v_tokens := array_append(v_tokens,v_rec.parts[1]);
            v_separators := array_append(v_separators,v_buffer);
            v_buffer := '';
        ELSE
            v_buffer := v_buffer || v_rec.parts[2];
        END IF;
    END LOOP;
    v_tail := v_buffer;
    v_n := cardinality(v_tokens);
    -- 8f.1 (v2.8). Detect two DIFFERENT complete word styles in one
    -- original name. Do not mistake a camel-cased word for a Titlecase
    -- word, and never infer this protection from an ALLCAPS original.
    SELECT coalesce(bool_or(t.token ~ '^[A-Z]{2,}$'),false),
           coalesce(bool_or(t.token ~ '^[A-Z][a-z]+$'),false)
      INTO v_has_uppercase_word,v_has_titlecase_word
    FROM unnest(v_tokens) AS t(token);
    v_existing_mixed_name := NOT v_allcaps_source
                             AND v_has_uppercase_word AND v_has_titlecase_word;
    -- 8f.2. Locate supported multi-token *dotted* legal designations.
    -- Only a phrase following a plausible company word is eligible; a
    -- trailing legal form or one immediately before a facility term qualifies.
    v_legal_token_outputs := array_fill(NULL::text,ARRAY[v_n]);
    IF v_n >= 3 THEN
        FOR v_j IN 2..v_n LOOP
            v_preceding_company_word := coalesce(v_tokens[v_j-1] ~ '^[[:alpha:]]{2,}$',false);
            IF NOT v_preceding_company_word THEN
                CONTINUE;
            END IF;
            -- Polish sp. z o.o. is three tokens. The spelling and dots
            -- must match, preventing accidental conversion of unrelated SP.
            IF v_j + 2 <= v_n
               AND upper(v_tokens[v_j])='SP'
               AND upper(v_tokens[v_j+1])='Z'
               AND upper(v_tokens[v_j+2])='O.O'
               AND v_separators[v_j+1] ~ '^[.][[:space:]]+$'
               AND v_separators[v_j+2] ~ '^[[:space:]]+$'
               AND (CASE WHEN v_j+2=v_n THEN v_tail ELSE v_separators[v_j+3] END) ~ '^[.]'
               AND (v_j+2=v_n OR upper(coalesce(v_tokens[v_j+3],''))=ANY(v_facility_terms))
            THEN
                v_legal_phrase := v_prescribed_forms[array_position(v_prescribed_keys,'SP_Z_OO')];
                v_phrase_chunks := string_to_array(v_legal_phrase,' ');
                FOR v_k IN 0..2 LOOP
                    v_legal_token_outputs[v_j+v_k] :=
                        regexp_replace(v_phrase_chunks[v_k+1],'[.]$','');
                END LOOP;
            END IF;
            -- Singaporean, Malaysian and Luxembourg legal forms have two
            -- dotted tokens; preserve their distinctive internal casing.
            IF v_j + 1 <= v_n
               AND (CASE
                    WHEN upper(v_tokens[v_j])='PTE' AND upper(v_tokens[v_j+1])='LTD'
                        THEN 'PTE_LTD'
                    WHEN upper(v_tokens[v_j])='SDN' AND upper(v_tokens[v_j+1])='BHD'
                        THEN 'SDN_BHD'
                    WHEN upper(v_tokens[v_j])='S.A' AND upper(v_tokens[v_j+1])='R.L'
                        THEN 'SA_RL'
                    END) IS NOT NULL
               AND (CASE WHEN upper(v_tokens[v_j])='S.A'
                         THEN v_separators[v_j+1] ~ '^[[:space:]]+$'
                         ELSE v_separators[v_j+1] ~ '^[.][[:space:]]+$'
                    END)
               AND (CASE WHEN v_j+1=v_n THEN v_tail ELSE v_separators[v_j+2] END) ~ '^[.]'
               AND (v_j+1=v_n OR upper(coalesce(v_tokens[v_j+2],''))=ANY(v_facility_terms))
            THEN
                v_legal_base := CASE
                    WHEN upper(v_tokens[v_j])='PTE' THEN 'PTE_LTD'
                    WHEN upper(v_tokens[v_j])='SDN' THEN 'SDN_BHD'
                    ELSE 'SA_RL' END;
                v_legal_phrase := v_prescribed_forms[array_position(v_prescribed_keys,v_legal_base)];
                v_phrase_chunks := string_to_array(v_legal_phrase,' ');
                v_legal_token_outputs[v_j] := regexp_replace(v_phrase_chunks[1],'[.]$','');
                v_legal_token_outputs[v_j+1] := regexp_replace(v_phrase_chunks[2],'[.]$','');
            END IF;
        END LOOP;
    END IF;

    IF v_n = 0 THEN
        formatted_name := v_s;
        IF length(p_name)>0 THEN
            v_review := array_append(v_review,'no_letters_or_numbers_after_cleaning');
        END IF;
    ELSE
        FOR v_i IN 1..v_n LOOP
            v_token := v_tokens[v_i];
            v_upper := upper(v_token);
            v_lower := lower(v_token);
            -- V2.10: most prescribed keys drop periods, but C.RO must be
            -- matched literally so an unrelated CRO token cannot match it.
            v_lookup := CASE WHEN v_upper='C.RO' THEN 'C.RO'
                             ELSE replace(v_upper,'.','') END;
            v_prev := lower(coalesce(v_tokens[v_i-1],''));
            v_next := lower(coalesce(v_tokens[v_i+1],''));
            v_next_upper := upper(coalesce(v_tokens[v_i+1],''));
            v_after := CASE WHEN v_i < v_n THEN v_separators[v_i+1] ELSE v_tail END;
            v_is_hyphen := v_separators[v_i] = '-' OR v_after = '-';
            v_is_standalone := NOT v_is_hyphen AND v_token ~ '^[[:alpha:]]+$';
            v_parenthesised := v_separators[v_i] ~ '\([[:space:]]*$'
                               AND v_after ~ '^[[:space:]]*\)';
            v_suffix := v_i = v_n OR (v_i=v_n-1 AND
                (v_next_upper=ANY(v_country_labels) OR v_next_upper=coalesce(v_country,'')));
            v_geo_candidate := v_is_standalone
                AND NOT (v_inverted AND v_i=v_n AND v_lower=ANY(ARRAY['de','of'])) AND
                (v_upper=ANY(v_all_regions) OR v_upper=ANY(ARRAY['AU','NO','CA'])
                 OR v_upper=coalesce(v_country,''));
            -- A-B and A&B are two one-letter identifiers, not two independent
            -- grammatical words; preserve/normalise both sides to uppercase.
            v_single_letter_connector :=
                (v_token ~ '^[A-Za-z]$' AND
                    ((v_after IN ('-','&') AND coalesce(v_tokens[v_i+1],'') ~ '^[A-Za-z]$') OR
                     (v_separators[v_i] IN ('-','&') AND coalesce(v_tokens[v_i-1],'') ~ '^[A-Za-z]$')));
            -- 8f.4 (v2.9). A pre-existing uppercase single letter immediately
            -- after a facility descriptor is a likely numbered/lettered
            -- facility label, not the English article 'a'. Also recognise
            -- the narrow 'Pier P1 NS - A East/West' structure; do not
            -- affect lowercase source 'a' or letter-connector rules.
            v_single_letter_facility_identifier :=
                v_token ~ '^[A-Z]$'
                AND NOT v_token=ANY(ARRAY['I','V','X'])
                AND NOT v_single_letter_connector
                AND (
                    (v_i>1
                     AND v_separators[v_i] ~ '^[[:space:]]+$'
                     AND (upper(coalesce(v_tokens[v_i-1],''))=ANY(v_facility_terms)
                          OR upper(coalesce(v_tokens[v_i-1],''))='PORT'))
                    OR
                    (v_i>=4
                     AND v_separators[v_i] ~ '^[[:space:]]*-[[:space:]]+$'
                     AND upper(coalesce(v_tokens[v_i-3],''))=ANY(v_facility_terms)
                     AND coalesce(v_tokens[v_i-2],'') ~* '^[A-Z]{1,5}[0-9]+[A-Z]?$'
                     AND coalesce(v_tokens[v_i-1],'') ~ '^[A-Z]{2,8}$'
                     AND (v_i=v_n OR v_next_upper=ANY(ARRAY['EAST','WEST','NORTH','SOUTH'])))
                );
            v_protected_identifier :=
                v_single_letter_connector
                OR (v_after='-' AND v_upper=ANY(ARRAY['PL','KS','VP1','W4','E1','M1'])
                                  AND v_next_upper='E')
                OR (v_separators[v_i]='-' AND v_upper='E'
                    AND upper(coalesce(v_tokens[v_i-1],''))=ANY(ARRAY['PL','KS','VP1','W4','E1','M1']))
                OR (v_type IN ('berth','shipyard berth') AND v_token='A'
                    AND v_prev=ANY(ARRAY['berth','jetty','pier','quay','wharf']));
            -- A whole ordinary word (SEA) or ordinary word + digits (SEA1)
            -- is title-cased, even if it looks like a facility code.
            v_geographic_word := (v_upper=ANY(v_geographic_words))
                OR (v_token ~* '^[[:alpha:]]{2,}[0-9]+$'
                    AND substring(v_upper FROM '^[[:alpha:]]+')=ANY(v_geographic_words));
            -- Numeric IDs are different from unconstrained standalone uppercase
            -- tokens. This preserves SB1/SB-1/PL-4, not standalone SB or SVI.
            v_structured_identifier :=
                (v_token ~* '^([A-Z]{1,5}[0-9]+[A-Z]?|[0-9]+[A-Z]{1,3})$')
                OR (v_token ~* '^[A-Z]{1,5}$'
                    AND v_after='-'
                    AND coalesce(v_tokens[v_i+1],'') ~ '^[0-9]+[[:alnum:]]*$');
            v_is_maritime_acronym := v_lookup=ANY(v_maritime_acronyms);
            v_prescribed_idx := array_position(v_prescribed_keys,v_lookup);
            v_following_facility := v_next_upper=ANY(v_facility_terms);
            v_preceding_company_word := v_i>1
                AND coalesce(v_tokens[v_i-1] ~ '^[[:alpha:]]{2,}$',false)
                AND (v_i>2 OR NOT
                    upper(coalesce(v_tokens[v_i-1],''))=ANY(v_facility_terms));
            v_legal_context := v_preceding_company_word
                AND (v_i=v_n OR v_following_facility);
            v_legal_current_is_dotted :=
                v_token ~* '^(s[.]r[.]l|s[.]p[.]a|s[.]r[.]o|d[.]o[.]o)$'
                AND v_after ~ '^[.]';
            v_ro_ro_token := v_upper='RO'
                AND ((v_after='-' AND v_next_upper='RO')
                     OR (v_separators[v_i]='-' AND upper(coalesce(v_tokens[v_i-1],''))='RO'));
            -- An exact already-formatted legal form is safe to leave alone,
            -- even if a facility word follows it. A new legal interpretation
            -- of an ALLCAPS token must pass the positional checks below.
            -- 8f.3 (v2.8). Protect existing ALL-UPPER tokens inside names
            -- already containing normal Titlecase words, including unusual
            -- prefix words that also happen to be grammatical particles
            -- (OG, AM). Do not try to recognise the company acronym itself.
            -- Ordinary geographic words, confirmed regional codes and the
            -- recognised grammatical exceptions retain their priority.
            v_preserve_mixed_upper :=
                v_mixed_case_source AND v_token ~ '^[A-Z]{2,}$'
                AND NOT v_geographic_word
                AND (
                    -- A correctly mixed name is reliable source evidence
                    -- even when the token is OG or AM, at ANY position.
                    v_existing_mixed_name
                    OR NOT v_lower=ANY(v_minors)
                    OR v_next_upper=ANY(v_facility_terms)
                    OR (upper(coalesce(v_tokens[v_i-1],''))=ANY(v_facility_terms)
                        AND NOT v_lower=ANY(v_multilingual_particles))
                )
                -- Grammatical connectors still become lowercase internally,
                -- unless reliable matching subdivision context confirms a
                -- regional code (e.g. DE = Delaware before 'Berth').
                -- Leading uppercase operator tokens stay protected.
                AND NOT (v_i>1 AND v_i<v_n
                         AND v_upper=ANY(v_clear_grammar_upper)
                         AND NOT (v_geo_candidate AND v_region_ok
                                  AND v_upper=v_region));
            -- DGzRS is a mixed-internal acronym; NorthWestbound is not.
            v_preserve_internal_mixed :=
                v_mixed_case_source AND v_token ~ '^[A-Za-z]{3,}$'
                AND v_token ~ '[A-Z]{2}' AND v_token ~ '[a-z]'
                AND NOT v_geographic_word
                AND NOT (v_lower ~ '^(north|south|east|west|northeast|northwest|southeast|southwest)(bound|ward|wards)?$');
            -- 8f.2 (v2.6). A lowercase-to-uppercase transition inside ONE
            -- alphabetic token is stronger evidence than the casing of
            -- neighbouring words, so beachB works even in ALLCAPS names.
            -- Reject known ordinary/minor and compass words; the rule
            -- branch is BELOW approved maritime, legal and code rules.
            v_preserve_inner_case :=
                v_token ~ '^[A-Za-z]{3,}$'
                AND v_token ~ '[a-z][A-Z]'
                AND NOT v_geographic_word
                AND NOT (v_lower=ANY(v_minors))
                AND NOT (v_lower ~ '^(north|south|east|west|northeast|northwest|southeast|southwest)(bound|ward|wards)?$');
            -- 8f.3 (v2.7). Protect a whole pre-existing lower/title-cased
            -- multilingual particle only within a partly title-cased name.
            -- ALLCAPS inputs, uppercase tokens and odd casing (such as dE)
            -- still pass to the established title-case/minor-word logic.
            v_preserve_multilingual_particle :=
                v_mixed_case_source
                AND v_i > 1 AND v_i < v_n
                AND v_is_standalone AND NOT v_is_hyphen
                AND v_lower=ANY(v_multilingual_particles)
                AND (v_token=v_lower OR v_token=initcap(v_lower))
                AND v_token<>v_upper;
            v_rule := NULL;
            v_candidate_reason := NULL;
            v_new := NULL;

            -- 8g. Apply the established precedence: named geographic and
            -- grammatical exceptions first, then codes and general title case.
            IF v_lower='v' AND v_next=ANY(ARRAY['slovenskih','podravski','pomurski','gorici','istri']) THEN
                v_rule := 'language_context_exceptions';
                v_new := CASE WHEN v_i=1 THEN 'V' ELSE 'v' END;
            ELSIF v_lower='do' AND v_prev='ong' THEN
                v_rule := 'language_context_exceptions'; v_new := 'Do';
            ELSIF (v_lower='wa' AND v_next='adh') OR (v_lower='adh' AND v_prev='wa') THEN
                v_rule := 'language_context_exceptions';
                v_new := CASE WHEN v_i=1 THEN initcap(v_lower) ELSE v_lower END;
            ELSIF v_lower='de' AND v_next=ANY(ARRAY['haandrik','bilt','ree']) THEN
                v_rule := 'proper_name_exceptions'; v_new := 'De';
            ELSIF v_lower='the' AND v_next='netherlands' THEN
                v_rule := 'proper_name_exceptions'; v_new := 'The';
            -- 8g.0 (v2.10). Exact No/NO with digits, optionally separated
            -- by a period, is the number abbreviation rather than a code.
            -- Only the first two letters are rewritten; do not add/remove
            -- a dot, or affect NO-3, NO3A, Norway NO, or other identifiers.
            ELSIF v_token ~* '^no[.]?[0-9]+$' THEN
                v_rule := 'number_followed_by_digits_standardised';
                v_new := 'No' || substr(v_token,3);
            ELSIF v_upper='NO' AND (v_next ~ '^[0-9]' OR v_after LIKE '.%') THEN
                v_rule := 'number_abbreviation'; v_new := 'No';
            ELSIF v_lower=ANY(ARRAY['st','appr','co']) AND v_after LIKE '.%' THEN
                v_rule := 'standard_abbreviations'; v_new := initcap(v_lower);
            -- 8g.1. Exact maritime spellings, including Ro-Ro pairs, take
            -- priority over general title case and original uppercase casing.
            ELSIF v_ro_ro_token THEN
                v_rule := 'prescribed_maritime_capitalisation'; v_new := 'Ro';
            ELSIF v_prescribed_idx IS NOT NULL
                AND v_prescribed_categories[v_prescribed_idx]='maritime_mixed_case'
                AND v_lookup<>'RO-RO' THEN
                v_rule := 'prescribed_maritime_capitalisation';
                v_new := v_prescribed_forms[v_prescribed_idx];
            -- 8g.1b (v2.10). The operator brand is an exact dotted token.
            -- Apply before generic title case and source-uppercase guards,
            -- without inventing a meaning for the undotted CRO acronym.
            ELSIF v_prescribed_idx IS NOT NULL
                AND v_prescribed_categories[v_prescribed_idx]='company_brand'
                AND v_token ~* '^C[.]RO$' THEN
                v_rule := 'company_brand_prescribed';
                v_new := v_prescribed_forms[v_prescribed_idx];
            -- Multiword legal forms were recognised against their entire
            -- dotted phrases before processing individual tokens.
            ELSIF v_legal_token_outputs[v_i] IS NOT NULL THEN
                v_rule := 'company_legal_form_prescribed';
                v_new := v_legal_token_outputs[v_i];
            -- Existing, already-correct distinctive forms are retained.
            -- Uppercase legal tokens are only reinterpreted as suffixes or
            -- immediately before facility terms in a plausible company name.
            ELSIF v_prescribed_idx IS NOT NULL
                AND v_prescribed_categories[v_prescribed_idx]='company_legal_form'
                AND (v_lookup=ANY(ARRAY['GMBH','GGMBH','APS'])
                     AND (v_legal_context OR v_token=v_prescribed_forms[v_prescribed_idx])) THEN
                v_rule := 'company_legal_form_prescribed';
                v_new := v_prescribed_forms[v_prescribed_idx];
            ELSIF v_prescribed_idx IS NOT NULL
                AND v_prescribed_categories[v_prescribed_idx]='company_legal_form'
                AND v_lookup=ANY(ARRAY['SRL','SRO','DOO','SPA'])
                AND v_legal_current_is_dotted
                AND v_legal_context THEN
                v_rule := 'company_legal_form_prescribed';
                -- The source separator already contains the final period.
                v_new := left(v_prescribed_forms[v_prescribed_idx],
                              length(v_prescribed_forms[v_prescribed_idx])-1);
            ELSIF v_prescribed_idx IS NOT NULL
                AND v_prescribed_categories[v_prescribed_idx]='company_legal_form'
                AND v_lookup=ANY(ARRAY['LLC','LLP','PLC','AG','BV','NV'])
                AND v_i=v_n AND v_preceding_company_word
                AND NOT (v_lookup='NV' AND v_country_ok AND v_country='US') THEN
                v_rule := 'company_legal_form_prescribed';
                v_new := v_prescribed_forms[v_prescribed_idx];
            -- APS as an uppercase prefix is not treated as the Danish ApS.
            -- Likewise, preserve uppercase German forms at the beginning
            -- and flag the uncertain meaning rather than silently guessing.
            ELSIF v_i=1 AND v_n>1 AND v_token=ANY(ARRAY['APS','GMBH','GGMBH']) THEN
                v_rule := 'ambiguous_company_prefix_preserved';
                v_new := v_token;
                v_review := array_append(v_review,'possible_company_form_prefix:'||v_token);
            -- 8g.4 (v2.9). This source-case rule outranks the minor-word
            -- conversion for a facility label but does not uppercase an
            -- already-lowercase article. A after Port is reviewable.
            ELSIF v_single_letter_facility_identifier THEN
                v_rule := 'single_letter_facility_identifier_preserved';
                v_new := v_token;
                IF v_token='A' AND v_prev='port' THEN
                    v_review := array_append(v_review,'ambiguous_port_a_facility_label');
                END IF;
            ELSIF v_protected_identifier THEN
                v_rule := 'identifiers'; v_new := v_upper;
            ELSIF v_upper='NM' AND v_prev ~ '^[0-9]+([.][0-9]+)?$' THEN
                v_rule := 'units'; v_new := 'NM';
            ELSIF v_geo_candidate AND v_region_ok AND v_upper=v_region
                  AND (v_suffix OR v_parenthesised OR NOT v_upper=ANY(v_ambiguous)) THEN
                v_rule := 'geographic_abbreviations'; v_new := v_upper;
                v_geographic_matches := array_append(v_geographic_matches,v_upper);
            ELSIF v_lookup=ANY(v_acronyms) THEN
                v_rule := 'acronyms'; v_new := v_upper;
                v_acronym_matches := array_append(v_acronym_matches,v_upper);
            -- Keep the original compass rule and its audit label, including
            -- camel-cased words such as NorthWestbound.
            ELSIF v_lower ~ '^(north|south|east|west|northeast|northwest|southeast|southwest)(bound|ward|wards)?$' THEN
                v_rule := 'compass_compounds'; v_new := initcap(v_lower);
            ELSIF v_geographic_word THEN
                v_rule := 'geographic_word_recognised'; v_new := initcap(v_lower);
            ELSIF v_upper ~ '^[0-9]+([.][0-9]+)?(MW|NM)$' THEN
                v_rule := 'units'; v_new := v_upper;
            -- 8g.6 (v2.9). The tokenizer retains a trailing apostrophe in
            -- a token such as II', so match the numeral before that quote
            -- and then reattach it. The existing apostrophe-name logic
            -- still handles O'Higgins, d'Oran, and non-Roman endings.
            ELSIF length(v_token)>1 AND right(v_token,1)=chr(39)
                  AND upper(left(v_token,length(v_token)-1))
                      ~ '^(X{0,3})(IX|IV|V?I{0,3})$' THEN
                v_rule := 'roman_numerals';
                v_new := upper(left(v_token,length(v_token)-1)) || chr(39);
                v_romans := array_append(v_romans,upper(left(v_token,length(v_token)-1)));
            ELSIF v_upper ~ '^(X{0,3})(IX|IV|V?I{0,3})$' AND v_upper<>'' THEN
                v_rule := 'roman_numerals'; v_new := v_upper;
                v_romans := array_append(v_romans,v_upper);
            ELSIF v_lower ~ '^[0-9]+(st|nd|rd|th)$' THEN
                v_rule := 'ordinals'; v_new := v_lower;
            ELSIF v_structured_identifier THEN
                v_rule := 'identifiers'; v_new := v_upper;
            -- These are not assumed to be established acronyms. The only
            -- evidence is the user's deliberate pre-existing source casing.
            ELSIF v_preserve_internal_mixed THEN
                v_rule := 'mixed_case_internal_acronym_preserved'; v_new := v_token;
            -- 8g.2. For other previously unrecognised camel/mixed-case
            -- tokens, preserve the exact letters without freezing the
            -- rest of the name's title-case conversion.
            ELSIF v_preserve_inner_case THEN
                v_rule := 'internal_mixed_case_preserved'; v_new := v_token;
            ELSIF v_preserve_mixed_upper THEN
                v_rule := 'mixed_case_uppercase_token_preserved'; v_new := v_token;
            -- 8g.3. Explicit grammatical expressions (de la / de le /
            -- de les) outrank preservation of an individual capitalised De.
            -- This avoids mistaking a French/Spanish preposition for an
            -- established Dutch proper-name article.
            ELSIF v_lower='de' AND v_i>1 AND v_i<v_n
                  AND NOT v_is_hyphen AND v_next=ANY(ARRAY['la','le','les']) THEN
                v_rule := 'minor_words'; v_new := 'de';
            -- Preserve only the SOURCE spelling of recognised particles;
            -- other words in the name continue through their normal rules.
            ELSIF v_preserve_multilingual_particle THEN
                v_rule := 'multilingual_particle_case_preserved';
                v_new := v_token;
                -- A capitalised De is often an official Dutch article, but
                -- geography alone cannot prove the source name's language.
                -- Do not rewrite it; flag non-NL/unknown cases for review.
                IF v_lower='de' AND v_token='De'
                   AND NOT (v_country_ok AND v_country='NL') THEN
                    v_review := array_append(v_review,'capitalised_de_language_unconfirmed');
                END IF;
            ELSIF position(chr(39) in v_token)>0 THEN
                v_rule := 'apostrophe_casing';
                v_parts := string_to_array(v_token,chr(39));
                IF lower(v_parts[1])=ANY(ARRAY['d','l','o']) AND cardinality(v_parts)>=2 THEN
                    v_prefix := CASE
                        WHEN lower(v_parts[1])='o' OR v_i=1 OR v_is_hyphen
                             OR v_lower='l''example' THEN upper(v_parts[1])
                        ELSE lower(v_parts[1]) END;
                    v_new := v_prefix || chr(39) || initcap(lower(v_parts[2]));
                    IF cardinality(v_parts)>2 THEN
                        FOR v_j IN 3..cardinality(v_parts) LOOP
                            v_new := v_new || chr(39) || lower(v_parts[v_j]);
                        END LOOP;
                    END IF;
                ELSE
                    v_new := initcap(lower(v_parts[1]));
                    IF cardinality(v_parts)>1 THEN
                        FOR v_j IN 2..cardinality(v_parts) LOOP
                            v_new := v_new || chr(39) || lower(v_parts[v_j]);
                        END LOOP;
                    END IF;
                END IF;
            -- Ordinary internal particles are NOT uppercased just because
            -- their country has a state/province with that code.
            ELSIF v_lower=ANY(v_minors) AND v_i>1 AND v_i<v_n
                  AND NOT v_is_hyphen AND NOT v_parenthesised AND NOT v_suffix THEN
                v_rule := 'minor_words'; v_new := v_lower;
            ELSIF v_geo_candidate AND v_country_ok AND v_suffix
                  AND v_upper=v_country THEN
                v_rule := 'geographic_abbreviations'; v_new := v_upper;
                v_geographic_matches := array_append(v_geographic_matches,v_upper);
                IF v_upper=ANY(v_ambiguous) THEN
                    v_review := array_append(v_review,'country_code_suffix_interpretation:'||v_upper);
                END IF;
            ELSIF v_geo_candidate AND v_country_ok AND NOT v_region_ok
                  AND v_region IS NULL AND v_suffix
                  AND v_upper=ANY(v_region_codes) THEN
                v_rule := 'geographic_abbreviations'; v_new := v_upper;
                v_geographic_matches := array_append(v_geographic_matches,v_upper);
                v_review := array_append(v_review,'regional_code_country_only:'||v_upper);
            ELSIF v_geo_candidate AND (v_suffix OR v_parenthesised
                  OR (NOT v_country_ok AND NOT v_upper=ANY(v_ambiguous) AND v_token=v_upper)) THEN
                IF NOT v_country_ok AND NOT v_upper=ANY(v_ambiguous) THEN
                    v_rule := 'geographic_abbreviations'; v_new := v_upper;
                    v_geographic_matches := array_append(v_geographic_matches,v_upper);
                    v_review := array_append(v_review,'geographic_code_unconfirmed:'||v_upper);
                ELSE
                    -- Crucial conservative fallback: do not force an ambiguous
                    -- suffix up or down in case while its geography is unknown.
                    v_rule := 'ambiguous_geographic_code_preserved'; v_new := v_token;
                    v_review := array_append(v_review,'ambiguous_geographic_suffix:'||v_upper);
                END IF;
            ELSIF v_lower=ANY(v_minors) AND v_i>1 AND v_i<v_n AND NOT v_is_hyphen THEN
                v_rule := 'minor_words'; v_new := v_lower;
            -- 8g.5 (v2.8). Only after ALL known title-case, grammar,
            -- abbreviation, geographic and company rules have been tried,
            -- retain original Titlecase/lowercase words in mixed names.
            -- This cannot override De la, multilingual particles or codes.
            ELSIF v_existing_mixed_name AND v_is_standalone
                  AND (v_token ~ '^[A-Z][a-z]+$'
                       OR (v_token ~ '^[a-z]+$' AND NOT v_lower=ANY(v_minors))) THEN
                v_rule := 'existing_mixed_case_name_preserved';
                v_new := v_token;
            ELSE
                v_rule := CASE WHEN v_i=1 OR v_i=v_n THEN 'first_last_word' ELSE 'title_case' END;
                v_new := initcap(v_lower);
            END IF;

            v_events := v_events || jsonb_build_array(jsonb_build_object(
                'rule',v_rule,'before',v_token,'after',v_new,'changed',v_token IS DISTINCT FROM v_new));
            -- Additional orthogonal audit flags: the original acronym/identifier
            -- rules remain visible and these labels identify WHY they applied.
            -- The legacy DGzRS branch still reports its original rule.
            -- Add the new common audit tag when it protected the same
            -- lowercase-to-uppercase pattern; avoid double-counting it.
            -- 8h (v2.8). Keep the whole-name structural safeguard visible
            -- when an earlier uppercase/camel-case rule did the protection.
            -- This is an additional audit event, not another conversion.
            IF v_existing_mixed_name
               AND v_new IS NOT DISTINCT FROM v_token
               AND v_rule=ANY(ARRAY[
                    'mixed_case_uppercase_token_preserved',
                    'mixed_case_internal_acronym_preserved',
                    'internal_mixed_case_preserved']) THEN
                v_events := v_events || jsonb_build_array(jsonb_build_object(
                    'rule','existing_mixed_case_name_preserved',
                    'before',v_token,'after',v_new,'changed',false,
                    'kind','preserve_only'));
            END IF;
            IF v_preserve_inner_case
               AND v_rule='mixed_case_internal_acronym_preserved' THEN
                v_events := v_events || jsonb_build_array(jsonb_build_object(
                    'rule','internal_mixed_case_preserved','before',v_token,
                    'after',v_new,'changed',false,'kind','preserve_only'));
            END IF;
            IF v_rule='compass_compounds' AND v_geographic_word THEN
                v_events := v_events || jsonb_build_array(jsonb_build_object(
                    'rule','geographic_word_recognised','before',v_token,
                    'after',v_new,'changed',v_token IS DISTINCT FROM v_new));
            END IF;
            IF v_rule='acronyms' AND v_is_maritime_acronym THEN
                v_events := v_events || jsonb_build_array(jsonb_build_object(
                    'rule','maritime_abbreviation_preserved','before',v_token,
                    'after',v_new,'changed',v_token IS DISTINCT FROM v_new));
            END IF;
            IF v_rule='identifiers' AND v_structured_identifier THEN
                v_events := v_events || jsonb_build_array(jsonb_build_object(
                    'rule','alphanumeric_identifier_preserved','before',v_token,
                    'after',v_new,'changed',v_token IS DISTINCT FROM v_new));
            END IF;
            IF v_rule='identifiers' AND v_single_letter_connector THEN
                v_events := v_events || jsonb_build_array(jsonb_build_object(
                    'rule','single_letter_connector_preserved','before',v_token,
                    'after',v_new,'changed',v_token IS DISTINCT FROM v_new));
            END IF;
            IF v_is_hyphen THEN
                v_events := v_events || jsonb_build_array(jsonb_build_object(
                    'rule','hyphenation','before',v_token,'after',v_new,'changed',v_token IS DISTINCT FROM v_new));
            END IF;
            -- 8h. Unknown uppercase prefixes outside the exact preserved
            -- berth pattern are flagged for review, not forcibly preserved.
            -- Review, but do not preserve, possible terminal-specific acronyms.
            -- Mixed-case input gives stronger evidence than all-uppercase input;
            -- in fully uppercase names, require a nearby facility term within
            -- three words. This can still flag legitimate proper nouns, which is
            -- why it is a REVIEW signal, not an automatic casing instruction.
            IF v_rule=ANY(ARRAY['first_last_word','title_case'])
               AND (v_token ~ '^[A-Z]{2,5}$'
                    OR (v_allcaps_source AND v_i=1
                        AND v_token ~ '^[A-Z]{6,8}$'))
               AND NOT v_upper=ANY(v_geographic_words)
               AND NOT v_lower=ANY(v_minors) THEN
                IF p_name ~ '[a-z]' THEN
                    v_candidate_reason := 'possible_unlisted_acronym:'||v_upper;
                ELSIF v_next_upper=ANY(v_facility_terms)
                   OR upper(coalesce(v_tokens[v_i+2],''))=ANY(v_facility_terms)
                   OR upper(coalesce(v_tokens[v_i+3],''))=ANY(v_facility_terms) THEN
                    v_candidate_reason := 'possible_facility_abbreviation:'||v_upper;
                ELSIF v_allcaps_source AND v_i=1 AND v_n BETWEEN 2 AND 4
                  AND (coalesce(v_tokens[v_i+1],'') ~ '^[0-9]+[A-Za-z]?$'
                    OR coalesce(v_tokens[v_i+1],'') ~ '^[A-Z]$') THEN
                    v_candidate_reason := 'possible_allcaps_identifier:'||v_upper;
                END IF;
                IF v_candidate_reason IS NOT NULL THEN
                    v_review := array_append(v_review,v_candidate_reason);
                    v_events := v_events || jsonb_build_array(jsonb_build_object(
                        'rule','acronym_review_candidate','before',v_token,
                        'after',v_new,'changed',false,'kind','review_only',
                        'reason',v_candidate_reason));
                    IF v_allcaps_source THEN
                        v_events := v_events || jsonb_build_array(jsonb_build_object(
                            'rule','allcaps_acronym_candidate','before',v_token,
                            'after',v_new,'changed',false,'kind','review_only',
                            'reason',v_candidate_reason));
                    END IF;
                END IF;
            END IF;
            v_result := v_result || v_separators[v_i] || v_new;
        END LOOP;
        v_s := v_result || v_tail;

        -- 8i. Rewrite only individually recognised foreign geographic phrases.
        -- No broad lowercase -E or administrative suffix rule is introduced.
        -- EXACT FOREIGN PHRASE EXCEPTIONS only. The regex word-boundaries are
        -- PostgreSQL \m / \M, not \b. No generic -E or Korean-suffix rewrite.
        FOR v_rec IN SELECT * FROM (VALUES
            ('Azarbayjan-E Gharbi','Azarbayjan-e Gharbi'),
            ('Bandar-E Mahshahr','Bandar-e Mahshahr'),
            ('Bandar-E Lengeh','Bandar-e Lengeh'),
            ('Taean-Gun','Taean-gun'),
            ('Seoul-Teukbyeolsi','Seoul-teukbyeolsi'),
            ('Chungcheongnam-Do','Chungcheongnam-do'),
            ('Sibensko-Kninska Zupanija','Sibensko-kninska Zupanija')
        ) AS x(match_phrase,formatted_phrase)
        LOOP
            IF v_s ~* ('\m'||v_rec.match_phrase||'\M') THEN
                v_before_step := v_s;
                v_s := regexp_replace(v_s,'\m'||v_rec.match_phrase||'\M',v_rec.formatted_phrase,'gi');
                v_events := v_events || jsonb_build_array(jsonb_build_object(
                    'rule','foreign_suffix_exceptions','before',v_before_step,'after',v_s,
                    'changed',v_before_step IS DISTINCT FROM v_s));
            END IF;
        END LOOP;
        formatted_name := v_s;
    END IF;

    -- 8j. Summarise applied/changed rule IDs and review reasons into the
    -- existing array and JSON outputs for downstream DBeaver validation.
    SELECT coalesce(array_agg(DISTINCT ev.value->>'rule' ORDER BY ev.value->>'rule'),ARRAY[]::text[]),
           coalesce(array_agg(DISTINCT ev.value->>'rule' ORDER BY ev.value->>'rule')
               FILTER (WHERE (ev.value->>'changed')::boolean),ARRAY[]::text[])
    INTO rules_applied,rules_changed
    FROM jsonb_array_elements(v_events) AS ev(value);
    rule_audit := v_events;
    SELECT coalesce(array_agg(DISTINCT q.s ORDER BY q.s),ARRAY[]::text[])
      INTO review_reasons FROM unnest(v_review) AS q(s);
    SELECT coalesce(array_agg(DISTINCT q.s ORDER BY q.s),ARRAY[]::text[])
      INTO roman_numerals FROM unnest(v_romans) AS q(s);
    SELECT coalesce(array_agg(DISTINCT q.s ORDER BY q.s),ARRAY[]::text[])
      INTO acronyms FROM unnest(v_acronym_matches) AS q(s);
    SELECT coalesce(array_agg(DISTINCT q.s ORDER BY q.s),ARRAY[]::text[])
      INTO geographic_abbreviations FROM unnest(v_geographic_matches) AS q(s);
    RETURN NEXT;
END;
$format$;

-- ============================================================================
-- 9. PREVIEW INSTALLATION / SOURCE-COLUMN MAPPING (v2.8)
-- No short-name source column is required, requested or inferred.
-- name_short = first 30 characters of the original full name.
-- name_short_formatted = first 30 characters of the FORMATTED full name.
-- This prevents applying context-sensitive title case to incomplete tokens.
-- Existing view columns retain their names/types/order for CREATE OR REPLACE.
-- Short-name rule flags describe the full-name processing that produced the
-- formatted prefix; they DO NOT assert that a rule visibly affects that prefix.
-- ============================================================================
DO $install_view$
DECLARE
    v_full_name_column text := 'zone_name';
    v_short_expr text;
BEGIN
    IF NOT EXISTS (SELECT 1 FROM pg_attribute AS a
        WHERE a.attrelid='geospatial.zones'::regclass
          AND a.attname=v_full_name_column AND a.attnum>0 AND NOT a.attisdropped) THEN
        RAISE EXCEPTION 'Full-name source column % does not exist.',v_full_name_column;
    END IF;
    v_short_expr := format('left(z.%I::text,30)',v_full_name_column);
    RAISE NOTICE 'Short names will be derived from full names, capped at 30 characters (no short-name source column needed).';

    EXECUTE format($view_sql$
        CREATE OR REPLACE VIEW sandbox.zone_name_title_case_preview_v2 AS
        -- 9a. Keep only eligible active zones and join geographic context
        -- optionally, so unmapped zones remain in the preview.
        WITH input_rows AS (
            SELECT z.zone_id AS fid,
                   z.%I::text AS name,
                   %s AS name_short,
                   z.zone_type_name::text AS zone_type_name,
                   z.zone_check_status::text AS zone_check_status,
                   %L::text AS source_name_column,
                   NULL::text AS source_name_short_column,
                   e.zone_id IS NOT NULL AS geography_row_available,
                   coalesce(to_jsonb(e),'{}'::jsonb) AS geo
            FROM geospatial.zones AS z
            LEFT JOIN sandbox.zone_geography_enriched AS e ON e.zone_id=z.zone_id
            WHERE z.zone_check_status::text IN ('Active','Active & curated')
        -- 9b. Read reference IDs, codes and provenance from the enrichment
        -- table, and compute whether conflicting geography needs caution.
        ), geography_fields AS (
            SELECT i.*,
                   nullif(i.geo->>'country_id','')::bigint AS country_id,
                   nullif(i.geo->>'country_sub_id','')::bigint AS country_sub_id,
                   upper(nullif(btrim(i.geo->>'country_iso2'),'')) AS country_iso2,
                   i.geo->>'country_name' AS country_name,
                   i.geo->>'country_sub_name' AS country_sub_name,
                   upper(nullif(btrim(i.geo->>'regional_abbreviation'),'')) AS raw_region_code,
                   regexp_replace(upper(coalesce(i.geo->>'country_sub_iso_code','')),
                                  '[-_[:space:]]','','g') AS cleaned_subdivision_code,
                   i.geo->>'country_sub_iso_code' AS country_sub_iso_code,
                   i.geo->>'country_source' AS country_source,
                   i.geo->>'subdivision_source' AS subdivision_source,
                   i.geo->>'generated_at' AS geography_generated_at,
                   coalesce(i.geo->>'review_reasons','') AS geography_review_reasons,
                   (
                       coalesce((i.geo->>'unknown_country_id')::boolean,false)
                       OR coalesce((i.geo->>'existing_country_conflict')::boolean,false)
                       OR coalesce((i.geo->>'existing_pair_mismatch')::boolean,false)
                       OR coalesce((i.geo->>'final_pair_mismatch')::boolean,false)
                       OR coalesce((i.geo->>'parent_country_conflict')::boolean,false)
                       OR coalesce((i.geo->>'related_port_country_conflict')::boolean,false)
                       OR coalesce((i.geo->>'sources_country_disagree')::boolean,false)
                       OR coalesce((i.geo->>'related_port_country_options')::integer,0)>1
                   ) AS geography_country_conflict,
                   (
                       coalesce((i.geo->>'unknown_subdivision_id')::boolean,false)
                       OR coalesce((i.geo->>'existing_sub_conflict')::boolean,false)
                       OR coalesce((i.geo->>'parent_sub_conflict')::boolean,false)
                       OR coalesce((i.geo->>'sources_subdivision_disagree')::boolean,false)
                       OR coalesce((i.geo->>'secondary_subdivision_incompatible')::boolean,false)
                       OR coalesce((i.geo->>'related_port_subdivision_options')::integer,0)>1
                   ) AS geography_subdivision_conflict,
                   (
                       coalesce((i.geo->>'country_source_overlap_pct')::numeric<1,false)
                       OR coalesce((i.geo->>'country_source_overlap_pct')::numeric
                                   -(i.geo->>'country_runnerup_overlap_pct')::numeric<1,false)
                   ) AS geography_country_low_confidence,
                   (
                       coalesce((i.geo->>'subdivision_source_overlap_pct')::numeric<1,false)
                       OR coalesce((i.geo->>'subdivision_source_overlap_pct')::numeric
                                   -(i.geo->>'subdivision_runnerup_overlap_pct')::numeric<1,false)
                   ) AS geography_subdivision_low_confidence
            FROM input_rows AS i
        -- 9c. Prepare ISO subdivision tokens without requiring every
        -- geographic row to have a state or province assignment.
        ), region_candidates AS (
            SELECT g.*,
                   CASE WHEN left(g.cleaned_subdivision_code,2)=g.country_iso2
                        THEN nullif(substring(g.cleaned_subdivision_code FROM 3),'')
                   END AS iso_region_code
            FROM geography_fields AS g
        -- 9d. Select credible regional codes and exclude contradictory
        -- source assignments from contextual abbreviation decisions.
        ), chosen_region AS (
            SELECT r.*,
                   CASE WHEN r.raw_region_code=ANY(sandbox.zntc_v2_region_codes(r.country_iso2))
                            THEN r.raw_region_code
                        WHEN r.iso_region_code=ANY(sandbox.zntc_v2_region_codes(r.country_iso2))
                            THEN r.iso_region_code
                   END AS regional_abbreviation,
                   (r.raw_region_code IS NOT NULL AND r.iso_region_code IS NOT NULL
                    AND r.raw_region_code<>r.iso_region_code) AS region_code_disagreement,
                   (r.country_id IS NOT NULL AND coalesce(r.country_iso2 ~ '^[A-Z]{2}$',false)
                    AND NOT r.geography_country_conflict
                    AND NOT r.geography_subdivision_conflict
                    AND NOT (r.raw_region_code IS NOT NULL AND r.iso_region_code IS NOT NULL
                             AND r.raw_region_code<>r.iso_region_code)
                    AND NOT r.geography_country_low_confidence) AS country_context_usable
            FROM region_candidates AS r
        -- 9e. Mark region context usable only when both country and
        -- subdivision evidence are consistent and sufficiently confident.
        ), context AS (
            SELECT c.*,
                   (c.country_context_usable AND c.country_sub_id IS NOT NULL
                    AND c.regional_abbreviation IS NOT NULL
                    AND NOT c.geography_subdivision_conflict
                    AND NOT c.geography_subdivision_low_confidence
                    AND NOT c.region_code_disagreement) AS region_context_usable
            FROM chosen_region AS c
        )
        -- 9f. Output the five requested names first, followed by the
        -- existing audit/geography fields and new preservation indicators.
        SELECT c.fid,
               c.name,
               nf.formatted_name AS name_formatted,
               c.name_short,
               left(nf.formatted_name,30) AS name_short_formatted,
               c.zone_type_name,
               c.zone_check_status,
               c.name IS DISTINCT FROM nf.formatted_name AS name_is_changed,
               c.name_short IS DISTINCT FROM left(nf.formatted_name,30) AS name_short_is_changed,
               (c.name IS DISTINCT FROM nf.formatted_name
                OR c.name_short IS DISTINCT FROM left(nf.formatted_name,30)) AS is_changed,
               c.source_name_column,
               c.source_name_short_column,
               c.source_name_short_column IS NOT NULL AS name_short_source_available,
               nf.cleaned_name AS name_cleaned,
               nf.corrected_name AS name_corrected,
               nf.reordered_name AS name_reordered,
               sf.cleaned_name AS name_short_cleaned,
               sf.corrected_name AS name_short_corrected,
               sf.reordered_name AS name_short_reordered,
               array_to_string(nf.rules_applied,' | ') AS name_applied_rules,
               array_to_string(nf.rules_changed,' | ') AS name_changed_rules,
               array_to_string(sf.rules_applied,' | ') AS name_short_applied_rules,
               array_to_string(sf.rules_changed,' | ') AS name_short_changed_rules,
               nf.rule_audit AS name_rule_audit,
               sf.rule_audit AS name_short_rule_audit,
               array_to_string(nf.roman_numerals,' | ') AS name_roman_numeral_tokens,
               array_to_string(sf.roman_numerals,' | ') AS name_short_roman_numeral_tokens,
               array_to_string(nf.acronyms,' | ') AS name_acronym_tokens,
               array_to_string(sf.acronyms,' | ') AS name_short_acronym_tokens,
               array_to_string(nf.geographic_abbreviations,' | ') AS name_geographic_code_tokens,
               array_to_string(sf.geographic_abbreviations,' | ') AS name_short_geographic_code_tokens,
           'diacritics_removed'=ANY(nf.rules_applied) AS name_diacritics_removed_applied,
           'apostrophes_normalised'=ANY(nf.rules_applied) AS name_apostrophes_normalised_applied,
           'commas_removed'=ANY(nf.rules_applied) AS name_commas_removed_applied,
           'whitespace_normalised'=ANY(nf.rules_applied) AS name_whitespace_normalised_applied,
           'anch_expanded'=ANY(nf.rules_applied) AS name_anch_expanded_applied,
           'drydock_corrected'=ANY(nf.rules_applied) AS name_drydock_corrected_applied,
           'leading_number_reordered'=ANY(nf.rules_applied) AS name_leading_number_reordered_applied,
           'first_last_word'=ANY(nf.rules_applied) AS name_first_last_word_applied,
           'minor_words'=ANY(nf.rules_applied) AS name_minor_words_applied,
           'proper_name_exceptions'=ANY(nf.rules_applied) AS name_proper_name_exceptions_applied,
           'language_context_exceptions'=ANY(nf.rules_applied) AS name_language_context_exceptions_applied,
           'hyphenation'=ANY(nf.rules_applied) AS name_hyphenation_applied,
           'apostrophe_casing'=ANY(nf.rules_applied) AS name_apostrophe_casing_applied,
           'acronyms'=ANY(nf.rules_applied) AS name_acronyms_applied,
           'geographic_abbreviations'=ANY(nf.rules_applied) AS name_geographic_abbreviations_applied,
           'ambiguous_geographic_code_preserved'=ANY(nf.rules_applied) AS name_ambiguous_geographic_code_preserved_applied,
           'compass_compounds'=ANY(nf.rules_applied) AS name_compass_compounds_applied,
           'roman_numerals'=ANY(nf.rules_applied) AS name_roman_numerals_applied,
           'foreign_suffix_exceptions'=ANY(nf.rules_applied) AS name_foreign_suffix_exceptions_applied,
           'identifiers'=ANY(nf.rules_applied) AS name_identifiers_applied,
           'units'=ANY(nf.rules_applied) AS name_units_applied,
           'diacritics_removed'=ANY(sf.rules_applied) AS name_short_diacritics_removed_applied,
           'apostrophes_normalised'=ANY(sf.rules_applied) AS name_short_apostrophes_normalised_applied,
           'commas_removed'=ANY(sf.rules_applied) AS name_short_commas_removed_applied,
           'whitespace_normalised'=ANY(sf.rules_applied) AS name_short_whitespace_normalised_applied,
           'anch_expanded'=ANY(sf.rules_applied) AS name_short_anch_expanded_applied,
           'drydock_corrected'=ANY(sf.rules_applied) AS name_short_drydock_corrected_applied,
           'leading_number_reordered'=ANY(sf.rules_applied) AS name_short_leading_number_reordered_applied,
           'first_last_word'=ANY(sf.rules_applied) AS name_short_first_last_word_applied,
           'minor_words'=ANY(sf.rules_applied) AS name_short_minor_words_applied,
           'proper_name_exceptions'=ANY(sf.rules_applied) AS name_short_proper_name_exceptions_applied,
           'language_context_exceptions'=ANY(sf.rules_applied) AS name_short_language_context_exceptions_applied,
           'hyphenation'=ANY(sf.rules_applied) AS name_short_hyphenation_applied,
           'apostrophe_casing'=ANY(sf.rules_applied) AS name_short_apostrophe_casing_applied,
           'acronyms'=ANY(sf.rules_applied) AS name_short_acronyms_applied,
           'geographic_abbreviations'=ANY(sf.rules_applied) AS name_short_geographic_abbreviations_applied,
           'ambiguous_geographic_code_preserved'=ANY(sf.rules_applied) AS name_short_ambiguous_geographic_code_preserved_applied,
           'compass_compounds'=ANY(sf.rules_applied) AS name_short_compass_compounds_applied,
           'roman_numerals'=ANY(sf.rules_applied) AS name_short_roman_numerals_applied,
           'foreign_suffix_exceptions'=ANY(sf.rules_applied) AS name_short_foreign_suffix_exceptions_applied,
           'identifiers'=ANY(sf.rules_applied) AS name_short_identifiers_applied,
           'units'=ANY(sf.rules_applied) AS name_short_units_applied,
               array_to_string(nf.review_reasons,' | ') AS name_review_reasons,
               array_to_string(sf.review_reasons,' | ') AS name_short_review_reasons,
               (cardinality(nf.review_reasons)>0 OR c.name IS NULL OR btrim(c.name)='') AS name_needs_review,
               cardinality(sf.review_reasons)>0 AS name_short_needs_review,
               (cardinality(nf.review_reasons)>0 OR cardinality(sf.review_reasons)>0
                OR c.name IS NULL OR btrim(c.name)=''
                OR c.geography_country_conflict OR c.geography_subdivision_conflict
                OR c.region_code_disagreement) AS requires_review,
               c.country_id,
               c.country_name,
               c.country_iso2,
               c.country_sub_id,
               c.country_sub_name,
               c.country_sub_iso_code,
               c.regional_abbreviation,
               c.country_source,
               c.subdivision_source,
               c.geography_row_available,
               c.country_context_usable,
               c.region_context_usable,
               c.geography_country_conflict,
               c.geography_subdivision_conflict,
               c.region_code_disagreement,
               c.geography_country_low_confidence,
               c.geography_subdivision_low_confidence,
               c.geography_review_reasons,
               c.geography_generated_at,
               'zone-title-case-v2.10'::text AS formatter_version,
               (c.name IS NOT NULL) AS name_short_generated,
               30::integer AS name_short_character_limit,
               coalesce(length(c.name)>30,false) AS name_short_truncated,
               coalesce(length(nf.formatted_name)>30,false) AS name_short_formatted_truncated,
               (coalesce(length(c.name)>30,false)
                OR coalesce(length(nf.formatted_name)>30,false))
                   AS name_short_any_truncation,
               coalesce((length(c.name)>30
                AND substring(c.name FROM 30 FOR 1) ~ '[[:alnum:]]'
                AND substring(c.name FROM 31 FOR 1) ~ '[[:alnum:]]'),false)
                   AS name_short_cut_midword,
               coalesce((length(nf.formatted_name)>30
                AND substring(nf.formatted_name FROM 30 FOR 1) ~ '[[:alnum:]]'
                AND substring(nf.formatted_name FROM 31 FOR 1) ~ '[[:alnum:]]'),false)
                   AS name_short_formatted_cut_midword,
               'left(original_full_name,30); left(formatted_full_name,30)'::text
                   AS name_short_generation_method,
               'full_name_processing_before_truncation'::text
                   AS name_short_rule_scope,
               -- 9g. Keep the V2.2 vocabulary flags in their original
               -- positions; add new flags ONLY at the end of the view.
               'geographic_word_recognised'=ANY(nf.rules_applied)
                   AS name_geographic_word_recognised,
               'maritime_abbreviation_preserved'=ANY(nf.rules_applied)
                   AS name_maritime_abbreviation_preserved,
               'alphanumeric_identifier_preserved'=ANY(nf.rules_applied)
                   AS name_alphanumeric_identifier_preserved,
               'acronym_review_candidate'=ANY(nf.rules_applied)
                   AS name_acronym_review_candidate,
               'geographic_word_recognised'=ANY(sf.rules_applied)
                   AS name_short_geographic_word_recognised,
               'maritime_abbreviation_preserved'=ANY(sf.rules_applied)
                   AS name_short_maritime_abbreviation_preserved,
               'alphanumeric_identifier_preserved'=ANY(sf.rules_applied)
                   AS name_short_alphanumeric_identifier_preserved,
               'acronym_review_candidate'=ANY(sf.rules_applied)
                   AS name_short_acronym_review_candidate,
               'mixed_case_berth_pattern_preserved'=ANY(nf.rules_applied)
                   AS name_preserved_mixed_case_berth_pattern,
               'mixed_case_berth_pattern_preserved'=ANY(sf.rules_applied)
                   AS name_short_preserved_mixed_case_berth_pattern,
               -- 9i. V2.4 flags are retained; never reorder earlier view
               -- columns because CREATE OR REPLACE VIEW requires compatibility.
               'mixed_case_uppercase_token_preserved'=ANY(nf.rules_applied)
                   AS name_mixed_case_uppercase_token_preserved,
               'mixed_case_uppercase_token_preserved'=ANY(sf.rules_applied)
                   AS name_short_mixed_case_uppercase_token_preserved,
               'mixed_case_internal_acronym_preserved'=ANY(nf.rules_applied)
                   AS name_mixed_case_internal_acronym_preserved,
               'mixed_case_internal_acronym_preserved'=ANY(sf.rules_applied)
                   AS name_short_mixed_case_internal_acronym_preserved,
               'single_letter_connector_preserved'=ANY(nf.rules_applied)
                   AS name_single_letter_connector_preserved,
               'single_letter_connector_preserved'=ANY(sf.rules_applied)
                   AS name_short_single_letter_connector_preserved,
               'allcaps_acronym_candidate'=ANY(nf.rules_applied)
                   AS name_allcaps_acronym_candidate,
               'allcaps_acronym_candidate'=ANY(sf.rules_applied)
                   AS name_short_allcaps_acronym_candidate,
               -- 9j. V2.5 audit flags remain in their original order; the
               -- first five output columns and earlier flag order are stable.
               'prescribed_maritime_capitalisation'=ANY(nf.rules_applied)
                   AS name_prescribed_maritime_capitalisation_applied,
               'prescribed_maritime_capitalisation'=ANY(sf.rules_applied)
                   AS name_short_prescribed_maritime_capitalisation_applied,
               'company_legal_form_prescribed'=ANY(nf.rules_applied)
                   AS name_company_legal_form_prescribed,
               'company_legal_form_prescribed'=ANY(sf.rules_applied)
                   AS name_short_company_legal_form_prescribed,
               'ambiguous_company_prefix_preserved'=ANY(nf.rules_applied)
                   AS name_ambiguous_company_prefix_preserved,
               'ambiguous_company_prefix_preserved'=ANY(sf.rules_applied)
                   AS name_short_ambiguous_company_prefix_preserved,
               -- 9k (v2.6). Report protection of an internal lower-to-
               -- uppercase letter transition; short flags inherit FULL
               -- name processing even if the token lies beyond 30 chars.
               'internal_mixed_case_preserved'=ANY(nf.rules_applied)
                   AS name_internal_mixed_case_preserved,
               'internal_mixed_case_preserved'=ANY(sf.rules_applied)
                   AS name_short_internal_mixed_case_preserved,
               -- 9l (v2.7). Append multilingual source-casing flags AFTER all
               -- previous columns so CREATE OR REPLACE VIEW stays compatible.
               'multilingual_particle_case_preserved'=ANY(nf.rules_applied)
                   AS name_multilingual_particle_case_preserved,
               'multilingual_particle_case_preserved'=ANY(sf.rules_applied)
                   AS name_short_multilingual_particle_case_preserved,
               -- 9m (v2.8). Append audit flags after all v2.7 columns;
               -- preserve their established names, types and positions.
               'existing_mixed_case_name_preserved'=ANY(nf.rules_applied)
                   AS name_existing_mixed_case_preserved,
               'existing_mixed_case_name_preserved'=ANY(sf.rules_applied)
                   AS name_short_existing_mixed_case_preserved,
               -- 9n (v2.9). Append new facility-letter audit columns so
               -- the existing view-column order stays compatible.
               'single_letter_facility_identifier_preserved'=ANY(nf.rules_applied)
                   AS name_single_letter_facility_identifier_preserved,
               'single_letter_facility_identifier_preserved'=ANY(sf.rules_applied)
                   AS name_short_single_letter_facility_identifier_preserved,
               -- 9o (v2.10). Append four audit flags; leave ALL existing
               -- preview columns untouched for CREATE OR REPLACE compatibility.
               'company_brand_prescribed'=ANY(nf.rules_applied)
                   AS name_company_brand_prescribed,
               'company_brand_prescribed'=ANY(sf.rules_applied)
                   AS name_short_company_brand_prescribed,
               'number_followed_by_digits_standardised'=ANY(nf.rules_applied)
                   AS name_number_followed_by_digits_standardised,
               'number_followed_by_digits_standardised'=ANY(sf.rules_applied)
                   AS name_short_number_followed_by_digits_standardised
        FROM context AS c
        CROSS JOIN LATERAL sandbox.zntc_v2_format(
            c.name,c.zone_type_name,c.country_iso2,c.regional_abbreviation,
            c.country_context_usable,c.region_context_usable
        ) AS nf
        CROSS JOIN LATERAL (
            SELECT left(nf.cleaned_name,30) AS cleaned_name,
                   left(nf.corrected_name,30) AS corrected_name,
                   left(nf.reordered_name,30) AS reordered_name,
                   nf.rules_applied, nf.rules_changed, nf.rule_audit,
                   nf.review_reasons, nf.roman_numerals, nf.acronyms,
                   nf.geographic_abbreviations
            -- 9h. Both 30-character short names are prefixes of the
            -- original or formatted FULL name, never independently processed.
        ) AS sf;
    $view_sql$,v_full_name_column,v_short_expr,v_full_name_column);
END;
$install_view$;

-- 10. Synthetic regression cases check expected text, audit flags,
-- review flags and repeat-processing consistency without changing zone data.
CREATE OR REPLACE VIEW sandbox.zone_name_title_case_regression_v2 AS
WITH test_cases AS (
    SELECT * FROM (VALUES
    ('null stays null',NULL,'Port',NULL,NULL,false,false,NULL,NULL,NULL),
    ('empty stays empty','','Port',NULL,NULL,false,false,'',NULL,NULL),
    ('no descriptor inserted','ROTTERDAM','Port',NULL,NULL,false,false,'Rotterdam',NULL,NULL),
    ('standalone number','12','Berth',NULL,NULL,false,false,'12',NULL,NULL),
    ('first and last minor','THE PORT OF','Port',NULL,NULL,false,false,'The Port Of',NULL,NULL),
    ('English minor words','THE PORT OF SPAIN AND THE SEA','Port',NULL,NULL,false,false,'The Port of Spain and the Sea',NULL,NULL),
    ('foreign particles','BAIA DE TODOS OS SANTOS','Port',NULL,NULL,false,false,'Baia de Todos os Santos','minor_words',NULL),
    ('French particles','ANSE AUX PINS','Port',NULL,NULL,false,false,'Anse aux Pins',NULL,NULL),
    ('German particles','PORT VON DER SEA','Port',NULL,NULL,false,false,'Port von der Sea',NULL,NULL),
    ('sur/des particles','PORT SUR DES EAUX','Port',NULL,NULL,false,false,'Port sur des Eaux',NULL,NULL),
    ('Off capitalised','OFF NJORD','Port',NULL,NULL,false,false,'Off Njord',NULL,NULL),
    ('long preposition','OFF LANDS END BETWEEN SEVEN STONES AND LONGSHIPS TSS','Port',NULL,NULL,false,false,'Off Lands End Between Seven Stones and Longships TSS',NULL,NULL),
    ('De Haandrik punctuation','KANAAL ALMELO DE HAANDRIK.','Port',NULL,NULL,false,false,'Kanaal Almelo De Haandrik.','proper_name_exceptions',NULL),
    ('De Bilt','PORT DE BILT','Port',NULL,NULL,false,false,'Port De Bilt',NULL,NULL),
    ('De Ree','KANAAL DE REE','Port',NULL,NULL,false,false,'Kanaal De Ree',NULL,NULL),
    ('The Netherlands comma','WADDEN SEA, THE NETHERLANDS.','Port',NULL,NULL,false,false,'Wadden Sea The Netherlands.',NULL,NULL),
    ('Slovenian v','PORT V SLOVENSKIH','Port',NULL,NULL,false,false,'Port v Slovenskih','language_context_exceptions',NULL),
    ('Slovenian v initial','V SLOVENSKIH','Port',NULL,NULL,false,false,'V Slovenskih',NULL,NULL),
    ('Ong Do','PORT ONG DO EAST','Port',NULL,NULL,false,false,'Port Ong Do East',NULL,NULL),
    ('wa adh','SHATT WA ADH DHIBAN','Port',NULL,NULL,false,false,'Shatt wa adh Dhiban',NULL,NULL),
    ('Wa adh initial','WA ADH DHIBAN','Port',NULL,NULL,false,false,'Wa adh Dhiban',NULL,NULL),
    ('hyphenated name','TUNAPUNA-PIARCO','Port',NULL,NULL,false,false,'Tunapuna-Piarco','hyphenation',NULL),
    ('hyphenated minor components','PORT-OF-SPAIN','Port',NULL,NULL,false,false,'Port-Of-Spain',NULL,NULL),
    -- v2.2: words versus standard acronyms versus structured code prefixes.
    ('geographic word sea','NORTH SEA','Port',NULL,NULL,false,false,'North Sea','geographic_word_recognised',NULL),
    ('geographic word bay','WEST BAY','Port',NULL,NULL,false,false,'West Bay','geographic_word_recognised',NULL),
    ('geographic word sea hyphen digit','SEA-1','Port',NULL,NULL,false,false,'Sea-1','geographic_word_recognised',NULL),
    ('geographic word sea joined digit','SEA1','Port',NULL,NULL,false,false,'Sea1','geographic_word_recognised',NULL),
    ('geographic word port joined digit','PORT1','Port',NULL,NULL,false,false,'Port1','geographic_word_recognised',NULL),
    ('structural word berth','SVI BERTH 1','Berth',NULL,NULL,false,false,'Svi Berth 1','geographic_word_recognised',true),
    ('maritime acronym SBM hyphen','SBM-1','Berth',NULL,NULL,false,false,'SBM-1','maritime_abbreviation_preserved',NULL),
    ('maritime acronym FPSO','FPSO NORTH SEA','Offshore Terminal',NULL,NULL,false,false,'FPSO North Sea','maritime_abbreviation_preserved',NULL),
    ('maritime acronym TSS','NORTHBOUND TSS','Port',NULL,NULL,false,false,'Northbound TSS','maritime_abbreviation_preserved',NULL),
    ('structured SB hyphen','SB-1','Berth',NULL,NULL,false,false,'SB-1','alphanumeric_identifier_preserved',NULL),
    ('structured lowercase sb hyphen','sb-1','Berth',NULL,NULL,false,false,'SB-1','alphanumeric_identifier_preserved',NULL),
    ('structured SB joined','SB1','Berth',NULL,NULL,false,false,'SB1','alphanumeric_identifier_preserved',NULL),
    ('structured AB12','AB12','Berth',NULL,NULL,false,false,'AB12','alphanumeric_identifier_preserved',NULL),
    ('structured PL-4','PL-4','Berth',NULL,NULL,false,false,'PL-4','alphanumeric_identifier_preserved',NULL),
    -- V2.4: intentional source case versus blanket ALLCAPS inference.
    ('CBM maritime acronym','OIL CBM NO 2','Port',NULL,NULL,false,false,'Oil CBM No 2','maritime_abbreviation_preserved',NULL),
    ('CBM title input','Oil Cbm No 2','Port',NULL,NULL,false,false,'Oil CBM No 2','maritime_abbreviation_preserved',NULL),
    ('mixed CGAEM','CGAEM South Outside Berth','Berth',NULL,NULL,false,false,'CGAEM South Outside Berth','mixed_case_uppercase_token_preserved',NULL),
    ('mixed ETA','ETA Terminal','Port',NULL,NULL,false,false,'ETA Terminal','mixed_case_uppercase_token_preserved',NULL),
    ('mixed OLI','Amerikahaven OLI Berth','Berth',NULL,NULL,false,false,'Amerikahaven OLI Berth','mixed_case_uppercase_token_preserved',NULL),
    ('mixed SEN','Amerikahaven SEN Berth','Berth',NULL,NULL,false,false,'Amerikahaven SEN Berth','mixed_case_uppercase_token_preserved',NULL),
    ('mixed SL','SL Floating Dock 1','Floating Dock',NULL,NULL,false,false,'SL Floating Dock 1','mixed_case_uppercase_token_preserved',NULL),
    ('mixed AEB','Nascheidingsinstallatie AEB','Port',NULL,NULL,false,false,'Nascheidingsinstallatie AEB','mixed_case_uppercase_token_preserved',NULL),
    ('mixed SB','Jiangnan SB 5','Berth',NULL,NULL,false,false,'Jiangnan SB 5','mixed_case_uppercase_token_preserved',NULL),
    ('mixed OH COMS','OH COMS North Berth','Berth',NULL,NULL,false,false,'OH COMS North Berth','mixed_case_uppercase_token_preserved',NULL),
    ('mixed AMC','Australian Marine Complex (AMC) Terminal','Terminal',NULL,NULL,false,false,'Australian Marine Complex (AMC) Terminal','mixed_case_uppercase_token_preserved',NULL),
    ('mixed DGzRS SAR','DGzRS - SAR Station Helgoland','Port',NULL,NULL,false,false,'DGzRS - SAR Station Helgoland','mixed_case_internal_acronym_preserved',NULL),
    ('mixed SE and VA','Kinder Morgan SE Terminals Richmond VA Berth 1','Berth','US','VA',true,true,'Kinder Morgan SE Terminals Richmond VA Berth 1','mixed_case_uppercase_token_preserved',NULL),
    ('mixed area titlecase','CGAEM South Outside AREA','Port',NULL,NULL,false,false,'CGAEM South Outside Area','geographic_word_recognised',NULL),
    ('grammatical DE LA exception','Port DE LA Selva','Port',NULL,NULL,false,false,'Port de la Selva','minor_words',NULL),
    ('upper letter ampersand','V&A Marina','Marina',NULL,NULL,false,false,'V&A Marina','single_letter_connector_preserved',NULL),
    ('mixed letter ampersand','V&a Marina','Marina',NULL,NULL,false,false,'V&A Marina','single_letter_connector_preserved',NULL),
    ('upper letter hyphen','V-A Marina','Marina',NULL,NULL,false,false,'V-A Marina','single_letter_connector_preserved',NULL),
    ('mixed letter hyphen','V-a Marina','Marina',NULL,NULL,false,false,'V-A Marina','single_letter_connector_preserved',NULL),
    ('unknown APO allcaps review','APO CEMENT TERMINAL','Terminal',NULL,NULL,false,false,'Apo Cement Terminal','allcaps_acronym_candidate',true),
    ('unknown STG W review','STG W','Port',NULL,NULL,false,false,'Stg W','allcaps_acronym_candidate',true),
    ('unknown CCT number review','CCT 1','Berth',NULL,NULL,false,false,'Cct 1','allcaps_acronym_candidate',true),
    ('unknown BBT berth review','BBT TANKER BERTH','Berth',NULL,NULL,false,false,'Bbt Tanker Berth','allcaps_acronym_candidate',true),
    ('preserve SVI mixed-case','SVI Berth 1','Berth',NULL,NULL,false,false,'SVI Berth 1','mixed_case_berth_pattern_preserved',false),
    -- v2.3: exact preservation is limited to correctly cased three-part
    -- berth names; near misses must continue through the normal formatter.
    ('preserve BEN berth','BEN Berth 2','Berth',NULL,NULL,false,false,'BEN Berth 2','mixed_case_berth_pattern_preserved',false),
    ('preserve short prefix','SB Berth 5','Berth',NULL,NULL,false,false,'SB Berth 5','mixed_case_berth_pattern_preserved',false),
    ('preserve 6-letter prefix','ABCDEF Berth 12','Berth',NULL,NULL,false,false,'ABCDEF Berth 12','mixed_case_berth_pattern_preserved',false),
    ('preserve optional number letter','XY Berth 3A','Berth',NULL,NULL,false,false,'XY Berth 3A','mixed_case_berth_pattern_preserved',false),
    ('preserve shipyard berth','PRMM Berth 01','Shipyard Berth',NULL,NULL,false,false,'PRMM Berth 01','mixed_case_berth_pattern_preserved',false),
    ('ordinary NORTH not acronym','NORTH Berth 1','Berth',NULL,NULL,false,false,'North Berth 1','geographic_word_recognised',NULL),
    ('ordinary MAIN not acronym','MAIN Berth 2','Berth',NULL,NULL,false,false,'Main Berth 2','geographic_word_recognised',NULL),
    ('ordinary SEA not acronym','SEA Berth 1','Berth',NULL,NULL,false,false,'Sea Berth 1','geographic_word_recognised',NULL),
    ('non berth zone type','SVI Berth 1','Port',NULL,NULL,false,false,'SVI Berth 1','mixed_case_uppercase_token_preserved',NULL),
    ('extra word not preserved','SVI Berth 1 East','Berth',NULL,NULL,false,false,'SVI Berth 1 East','mixed_case_uppercase_token_preserved',NULL),
    ('long prefix not preserved','ABCDEFG Berth 1','Berth',NULL,NULL,false,false,'ABCDEFG Berth 1','mixed_case_uppercase_token_preserved',NULL),
    ('multiple spaces not preserved','SVI  Berth 1','Berth',NULL,NULL,false,false,'SVI Berth 1','whitespace_normalised',NULL),
    ('unknown SVI full-uppercase','SVI BERTH 1','Berth',NULL,NULL,false,false,'Svi Berth 1','acronym_review_candidate',true),
    ('unknown SVI directional','SVI NORTH BERTHING AREA','Berth',NULL,NULL,false,false,'Svi North Berthing Area','acronym_review_candidate',true),
    ('mixed SB standalone','Jiangnan SB 9','Berth',NULL,NULL,false,false,'Jiangnan SB 9','mixed_case_uppercase_token_preserved',NULL),
    ('ordinary BAY numeric','BAY-1','Port',NULL,NULL,false,false,'Bay-1','geographic_word_recognised',NULL),
    -- V2.5: maritime acronyms and exact mixed-case forms.
    ('FSRU uppercase maritime','fsru TERMINAL','Offshore Terminal',NULL,NULL,false,false,'FSRU Terminal','maritime_abbreviation_preserved',NULL),
    ('FLNG uppercase maritime','FLNG TERMINAL','Offshore Terminal',NULL,NULL,false,false,'FLNG Terminal','maritime_abbreviation_preserved',NULL),
    ('FSU uppercase maritime','fsu NORTH SEA','Offshore Terminal',NULL,NULL,false,false,'FSU North Sea','maritime_abbreviation_preserved',NULL),
    ('RoRo mixed canonical','RORO TERMINAL','Port',NULL,NULL,false,false,'RoRo Terminal','prescribed_maritime_capitalisation',NULL),
    ('RoRo already formatted','RoRo Terminal','Port',NULL,NULL,false,false,'RoRo Terminal','prescribed_maritime_capitalisation',NULL),
    ('Ro-Ro hyphenated','RO-RO TERMINAL','Port',NULL,NULL,false,false,'Ro-Ro Terminal','prescribed_maritime_capitalisation',NULL),
    ('RoPax mixed canonical','ROPAX FERRY','Port',NULL,NULL,false,false,'RoPax Ferry','prescribed_maritime_capitalisation',NULL),
    ('AtoN mixed canonical','ATON STATION','Port',NULL,NULL,false,false,'AtoN Station','prescribed_maritime_capitalisation',NULL),
    ('MoU mixed canonical','MOU AREA','Port',NULL,NULL,false,false,'MoU Area','prescribed_maritime_capitalisation',NULL),
    -- Legal-form suffixes are position-sensitive; company jurisdiction is not
    -- assumed to match a zone country or subdivision.
    ('Danish ApS legal suffix','NORDIC SHIPPING APS','Port',NULL,NULL,false,false,'Nordic Shipping ApS','company_legal_form_prescribed',NULL),
    ('Danish ApS already correct','Nordic Shipping ApS Terminal','Port',NULL,NULL,false,false,'Nordic Shipping ApS Terminal','company_legal_form_prescribed',NULL),
    ('Danish APS prefix kept','APS Terminal 1','Terminal',NULL,NULL,false,false,'APS Terminal 1','ambiguous_company_prefix_preserved',true),
    ('Danish APS allcaps prefix kept','APS TERMINAL 1','Terminal',NULL,NULL,false,false,'APS Terminal 1','ambiguous_company_prefix_preserved',true),
    ('Danish company before terminal','NORDIC SHIPPING APS TERMINAL','Terminal',NULL,NULL,false,false,'Nordic Shipping ApS Terminal','company_legal_form_prescribed',NULL),
    ('German GmbH legal suffix','HAMBURG SHIPPING GMBH','Port',NULL,NULL,false,false,'Hamburg Shipping GmbH','company_legal_form_prescribed',NULL),
    ('German GmbH before berth','HAMBURG SHIPPING GMBH BERTH','Berth',NULL,NULL,false,false,'Hamburg Shipping GmbH Berth','company_legal_form_prescribed',NULL),
    ('German GmbH prefix not legal suffix','GMBH Terminal','Terminal',NULL,NULL,false,false,'GMBH Terminal','ambiguous_company_prefix_preserved',true),
    ('German gGmbH suffix','PORT SERVICES GGMBH','Port',NULL,NULL,false,false,'Port Services gGmbH','company_legal_form_prescribed',NULL),
    ('Italian s.r.l. suffix','BALTIC MARINE S.R.L.','Port',NULL,NULL,false,false,'Baltic Marine S.r.l.','company_legal_form_prescribed',NULL),
    ('Italian S.p.A. suffix','MARINE TRADING S.P.A.','Port',NULL,NULL,false,false,'Marine Trading S.p.A.','company_legal_form_prescribed',NULL),
    ('Polish legal form','POLISH TERMINALS SP. Z O.O.','Port',NULL,NULL,false,false,'Polish Terminals sp. z o.o.','company_legal_form_prescribed',NULL),
    ('Czech s.r.o. legal form','CZECH MARINE S.R.O.','Port',NULL,NULL,false,false,'Czech Marine s.r.o.','company_legal_form_prescribed',NULL),
    ('Croatian d.o.o. legal form','ADRIATIC MARINE D.O.O.','Port',NULL,NULL,false,false,'Adriatic Marine d.o.o.','company_legal_form_prescribed',NULL),
    ('Singapore Pte Ltd','SINGAPORE PORTS PTE. LTD.','Port',NULL,NULL,false,false,'Singapore Ports Pte. Ltd.','company_legal_form_prescribed',NULL),
    ('Malaysia Sdn Bhd','MALAYSIAN SHIPPING SDN. BHD.','Port',NULL,NULL,false,false,'Malaysian Shipping Sdn. Bhd.','company_legal_form_prescribed',NULL),
    ('Luxembourg transliterated legal form','MARINE SERVICES S.À R.L.','Port',NULL,NULL,false,false,'Marine Services S.a r.l.','company_legal_form_prescribed',NULL),
    ('LLC suffix','GLOBAL TERMINALS LLC','Port',NULL,NULL,false,false,'Global Terminals LLC','company_legal_form_prescribed',NULL),
    ('LLP suffix','GLOBAL TERMINALS LLP','Port',NULL,NULL,false,false,'Global Terminals LLP','company_legal_form_prescribed',NULL),
    ('PLC suffix','GLOBAL TERMINALS PLC','Port',NULL,NULL,false,false,'Global Terminals PLC','company_legal_form_prescribed',NULL),
    ('AG legal suffix','GERMAN PORTS AG','Port',NULL,NULL,false,false,'German Ports AG','company_legal_form_prescribed',NULL),
    ('BV legal suffix','DUTCH SHIPPING BV','Port',NULL,NULL,false,false,'Dutch Shipping BV','company_legal_form_prescribed',NULL),
    ('NV legal suffix','DUTCH SHIPPING NV','Port',NULL,NULL,false,false,'Dutch Shipping NV','company_legal_form_prescribed',NULL),
    ('legal LLP prefix not forced','LLP BERTH 2','Berth',NULL,NULL,false,false,'Llp Berth 2',NULL,true),
    ('legal PLC prefix not forced','PLC TERMINAL','Terminal',NULL,NULL,false,false,'Plc Terminal',NULL,true),
    ('ordinary AS not company','PORT AS THE SEA','Port',NULL,NULL,false,false,'Port As the Sea',NULL,NULL),
    ('ordinary SA no company rule','PORT SA','Port',NULL,NULL,false,false,'Port SA',NULL,true),
    ('ordinary NO before number','BERTH NO. 2','Berth',NULL,NULL,false,false,'Berth No. 2','number_abbreviation',NULL),
    ('Roman normal','THILAWA ANCHORAGE III','Port',NULL,NULL,false,false,'Thilawa Anchorage III','roman_numerals',NULL),
    ('Roman punctuation','PORT IV, SOUTH','Port',NULL,NULL,false,false,'Port IV South','roman_numerals',NULL),
    ('Roman hyphen','PORT IV-V','Port',NULL,NULL,false,false,'Port IV-V','roman_numerals',NULL),
    ('Roman range maximum','TERMINAL XXXIX','Port',NULL,NULL,false,false,'Terminal XXXIX',NULL,NULL),
    ('Roman 40 outside agreed range','TERMINAL XL','Port',NULL,NULL,false,false,'Terminal Xl',NULL,NULL),
    ('Roman in parentheses','PORT (VIII)','Port',NULL,NULL,false,false,'Port (VIII)',NULL,NULL),
    ('Roman conjunction','HUANENG DALIAN ZHUANGHE IV AND V','Port',NULL,NULL,false,false,'Huaneng Dalian Zhuanghe IV and V',NULL,NULL),
    ('phonetic apostrophe','HA''APAI','Port',NULL,NULL,false,false,'Ha''apai','apostrophe_casing',NULL),
    ('possessive apostrophe','KING''S WHARF','Port',NULL,NULL,false,false,'King''s Wharf',NULL,NULL),
    ('phonetic second word','BUR SA''ID','Port',NULL,NULL,false,false,'Bur Sa''id',NULL,NULL),
    ('internal Slavic apostrophe','ZABAYKAL''SKIY KRAY','Port',NULL,NULL,false,false,'Zabaykal''skiy Kray',NULL,NULL),
    ('trailing apostrophe','CHELYABINSKAYA OBLAST''','Port',NULL,NULL,false,false,'Chelyabinskaya Oblast''',NULL,NULL),
    ('O Higgins','O''HIGGINS','Port',NULL,NULL,false,false,'O''Higgins',NULL,NULL),
    ('O Neill possessive','O''NEILL''S WHARF','Port',NULL,NULL,false,false,'O''Neill''s Wharf',NULL,NULL),
    ('elision internal','PORT D''ORAN','Port',NULL,NULL,false,false,'Port d''Oran',NULL,NULL),
    ('elision first','D''ORAN','Port',NULL,NULL,false,false,'D''Oran',NULL,NULL),
    ('elision L','L''HERAULT','Port',NULL,NULL,false,false,'L''Herault',NULL,NULL),
    ('apostrophe OR not Oregon','CALA D''OR','Port','ES',NULL,true,false,'Cala d''Or',NULL,NULL),
    ('elision hyphen','SAINT-D''ORAN','Port',NULL,NULL,false,false,'Saint-D''Oran',NULL,NULL),
    ('explicit L example','PORT L''EXAMPLE','Port',NULL,NULL,false,false,'Port L''Example',NULL,NULL),
    ('curly apostrophe','O’HIGGINS','Port',NULL,NULL,false,false,'O''Higgins','apostrophes_normalised',NULL),
    ('mojibake apostrophe','Oâ€™HIGGINS','Port',NULL,NULL,false,false,'O''Higgins',NULL,NULL),
    ('diacritics','SÃO PAULO','Port',NULL,NULL,false,false,'Sao Paulo','diacritics_removed',NULL),
    ('diacritics lowercase','Málaga','Port',NULL,NULL,false,false,'Malaga',NULL,NULL),
    ('decomposed diacritics','São Paulo','Port',NULL,NULL,false,false,'Sao Paulo',NULL,NULL),
    ('paired lower-case mapping','ÅLESUND ÆRØ ß','Port',NULL,NULL,false,false,'Alesund Aero Ss',NULL,NULL),
    ('underscores','NORTH_SEA','Port',NULL,NULL,false,false,'North Sea','underscores_to_spaces',NULL),
    ('space normalisation','  PORT	 OF  SPAIN
','Port',NULL,NULL,false,false,'Port of Spain','whitespace_normalised',NULL),
    ('dash','NORTH–SOUTH','Port',NULL,NULL,false,false,'North-South','dashes_normalised',NULL),
    ('backslash','NORTH\SOUTH','Port',NULL,NULL,false,false,'North-South','backslashes_to_hyphens',NULL),
    ('comma does not join words','PORT,SOUTH','Port',NULL,NULL,false,false,'Port South','commas_removed',NULL),
    ('inversion not reversed','ASTURIAS, PRINCIPALITY OF','Port',NULL,NULL,false,false,'Asturias Principality Of',NULL,true),
    ('inverted de last capital','ASTURIAS, PRINCIPADO DE','Port',NULL,NULL,false,false,'Asturias Principado De',NULL,true),
    ('inverted colon','BRUXELLES-CAPITALE: REGION DE','Port',NULL,NULL,false,false,'Bruxelles-Capitale Region De',NULL,true),
    ('plus original no spaces','A+B','Port',NULL,NULL,false,false,'A&B','plus_to_ampersand',NULL),
    ('plus original spaces','A + B','Port',NULL,NULL,false,false,'A & B',NULL,NULL),
    ('plus unequal spacing retained','A+ B','Port',NULL,NULL,false,false,'A+ B',NULL,true),
    ('unwanted marks','PORT#SOUTH','Port',NULL,NULL,false,false,'Port South','unwanted_symbols_removed',NULL),
    ('periods retained','ST. JOHN APPR.','Port',NULL,NULL,false,false,'St. John Appr.',NULL,NULL),
    ('company not Colorado','CO. MARINA','Port','US','CO',true,true,'Co. Marina',NULL,NULL),
    ('No is not Norway','BERTH NO. 302','Berth','NO',NULL,true,false,'Berth No. 302','number_abbreviation',NULL),
    ('No before a number','BERTH NO 302','Berth',NULL,NULL,false,false,'Berth No 302',NULL,NULL),
    ('dotted country acronym','U.S. COAST GUARD','Port',NULL,NULL,false,false,'U.S. Coast Guard',NULL,NULL),
    ('acronym punctuation','GOUGH ISLAND AND SURROUNDING WATERS IMMA,','Port',NULL,NULL,false,false,'Gough Island and Surrounding Waters IMMA','acronyms',NULL),
    ('acronym slash','LNG/LPG TERMINAL','Port',NULL,NULL,false,false,'LNG/LPG Terminal',NULL,NULL),
    ('maritime whitelist','FPSO OT OSI FPS FSO STS SBM SPM MBM','Port',NULL,NULL,false,false,'FPSO OT OSI FPS FSO STS SBM SPM MBM',NULL,NULL),
    ('ancillary whitelist','BBC EH IMMA ECA TSS MARPOL MW OWF FA SRR MICT UKMTO UTAG','Port',NULL,NULL,false,false,'BBC EH IMMA ECA TSS MARPOL MW OWF FA SRR MICT UKMTO UTAG',NULL,NULL),
    ('attached unit','FARM 500MW','Port',NULL,NULL,false,false,'Farm 500MW','units',NULL),
    ('decimal unit','ZONE 12.5nm','Port',NULL,NULL,false,false,'Zone 12.5NM',NULL,NULL),
    ('separate NM not state','12 NM LIMIT','Port','US','NM',true,true,'12 NM Limit','units',NULL),
    ('ordinal','21ST PIER','Port',NULL,NULL,false,false,'21st Pier','ordinals',NULL),
    ('alphanumeric','BERTH R4','Berth',NULL,NULL,false,false,'Berth R4','identifiers',NULL),
    ('berth A is identifier','BERTH A EAST','Berth',NULL,NULL,false,false,'Berth A East',NULL,NULL),
    ('letter range','QUAYS A-E','Port',NULL,NULL,false,false,'Quays A-E',NULL,NULL),
    ('protected PL E','PL-E','Berth',NULL,NULL,false,false,'PL-E',NULL,NULL),
    ('protected W4 E','W4-E','Anchorage',NULL,NULL,false,false,'W4-E',NULL,NULL),
    ('protected VP1 E','VP1-E','Berth',NULL,NULL,false,false,'VP1-E',NULL,NULL),
    ('foreign e Bandar','BANDAR-E LENGEH','Port',NULL,NULL,false,false,'Bandar-e Lengeh','foreign_suffix_exceptions',NULL),
    ('foreign e Mahshahr','BANDAR-E MAHSHAHR','Port',NULL,NULL,false,false,'Bandar-e Mahshahr',NULL,NULL),
    ('foreign e Azarbayjan','AZARBAYJAN-E GHARBI','Port',NULL,NULL,false,false,'Azarbayjan-e Gharbi',NULL,NULL),
    ('no blanket e','NEWPLACE-E','Port',NULL,NULL,false,false,'Newplace-E',NULL,NULL),
    ('named Taean gun','TAEAN-GUN','Port',NULL,NULL,false,false,'Taean-gun',NULL,NULL),
    ('named Seoul suffix','SEOUL-TEUKBYEOLSI','Port',NULL,NULL,false,false,'Seoul-teukbyeolsi',NULL,NULL),
    ('named Korean do','CHUNGCHEONGNAM-DO','Port',NULL,NULL,false,false,'Chungcheongnam-do',NULL,NULL),
    ('named Croatian exception','SIBENSKO-KNINSKA ZUPANIJA','Port',NULL,NULL,false,false,'Sibensko-kninska Zupanija',NULL,NULL),
    ('no blanket gun','OTHER-GUN','Port',NULL,NULL,false,false,'Other-Gun',NULL,NULL),
    ('foreign phrase substring protected','NOTTAEAN-GUN','Port',NULL,NULL,false,false,'Nottaean-Gun',NULL,NULL),
    ('compass camelcase','NorthWestbound','Port',NULL,NULL,false,false,'Northwestbound','compass_compounds',NULL),
    ('foreign administrative words','KHANTY-MANSIYSKIY AVTONOMNYY OKRUG','Port',NULL,NULL,false,false,'Khanty-Mansiyskiy Avtonomnyy Okrug',NULL,NULL),
    ('anch expansion','SINGAPORE ANCH','Anchorage',NULL,NULL,false,false,'Singapore Anchorage','anch_expanded',NULL),
    ('anch abbreviation dot','SINGAPORE ANCH.','Anchorage',NULL,NULL,false,false,'Singapore Anchorage',NULL,NULL),
    ('ANCH no wrong type expansion','SINGAPORE ANCH','Port',NULL,NULL,false,false,'Singapore Anch',NULL,NULL),
    ('anch substring unchanged','ANCHOR POINT','Anchorage',NULL,NULL,false,false,'Anchor Point',NULL,NULL),
    ('no anch insertion','SINGAPORE','Anchorage',NULL,NULL,false,false,'Singapore',NULL,NULL),
    ('drydock split','DRYDOCK 4','Dry Dock',NULL,NULL,false,false,'Dry Dock 4','drydock_corrected',NULL),
    ('drydocks plural','EAST DRYDOCKS','Shipyard',NULL,NULL,false,false,'East Dry Docks',NULL,NULL),
    ('drydock substring unchanged','DRYDOCKING','Port',NULL,NULL,false,false,'Drydocking',NULL,NULL),
    ('two independent corrections','DRYDOCK ANCH','Anchorage',NULL,NULL,false,false,'Dry Dock Anchorage',NULL,NULL),
    ('reorder berth','12 BERTH','Berth',NULL,NULL,false,false,'Berth 12','leading_number_reordered',NULL),
    ('reorder berth with letter','12A BERTH','Berth',NULL,NULL,false,false,'Berth 12A',NULL,NULL),
    ('reorder shipyard berth','12 SHIPYARD BERTH','Shipyard Berth',NULL,NULL,false,false,'Shipyard Berth 12',NULL,NULL),
    ('reorder drydock combined','4 DRYDOCK','Dry Dock',NULL,NULL,false,false,'Dry Dock 4',NULL,NULL),
    ('reorder floating dock','5 FLOATING DOCK','Floating Dock',NULL,NULL,false,false,'Floating Dock 5',NULL,NULL),
    ('reorder slipway','3 SLIPWAY','Slipway',NULL,NULL,false,false,'Slipway 3',NULL,NULL),
    ('reorder shipyard','2 SHIPYARD','Shipyard',NULL,NULL,false,false,'Shipyard 2',NULL,NULL),
    ('no reorder complex','12 NORTH BERTH','Berth',NULL,NULL,false,false,'12 North Berth',NULL,true),
    ('no reorder incompatible type','12 BERTH','Port',NULL,NULL,false,false,'12 Berth',NULL,NULL),
    ('no reorder proper name','7 SEAS','Berth',NULL,NULL,false,false,'7 Seas',NULL,NULL),
    ('Dover DE exact region','DOVER de','Port','US','DE',true,true,'Dover DE','geographic_abbreviations',NULL),
    ('Portland OR country only','PORTLAND or','Port','US',NULL,true,false,'Portland OR',NULL,true),
    ('grammar despite same country','BURNHAM ON CROUCH FERRY LANDING','Port','CA','ON',true,true,'Burnham on Crouch Ferry Landing',NULL,NULL),
    ('Spanish grammatical words','PORT DE LA SELVA','Port','ES',NULL,true,false,'Port de la Selva',NULL,NULL),
    ('country AU suffix','BRIGHTON au','Port','AU',NULL,true,false,'Brighton AU',NULL,NULL),
    ('French au particle','MARINA AU QUAI DU CAPITAINE','Port','CA','QC',true,true,'Marina au Quai du Capitaine',NULL,NULL),
    ('German DE suffix','HAREN de','Port','DE',NULL,true,false,'Haren DE',NULL,NULL),
    ('Canada CA suffix','STEPHENVILLE ca','Port','CA','NL',true,true,'Stephenville CA',NULL,NULL),
    ('region before country suffix','DOVER de USA','Port','US','DE',true,true,'Dover DE USA',NULL,NULL),
    ('parenthesised regional code','PORT (on) EAST','Port','CA','ON',true,true,'Port (ON) East',NULL,NULL),
    ('non-suffix regional code','nsw PORT AUTHORITY','Port','AU','NSW',true,true,'NSW Port Authority',NULL,NULL),
    ('missing geo ambiguous lower suffix','DOVER de','Port',NULL,NULL,false,false,'Dover de',NULL,true),
    ('missing geo ambiguous upper suffix','DOVER DE','Port',NULL,NULL,false,false,'Dover DE',NULL,true),
    ('conflicting geo ambiguous suffix','DOVER de','Port','US','DE',false,false,'Dover de',NULL,true),
    ('missing geo unambiguous TX','BROWNSVILLE tx','Port',NULL,NULL,false,false,'Brownsville TX','geographic_abbreviations',true),
    ('known region disagreement','PORT de','Port','US','TX',true,true,'Port de',NULL,true),
    ('mixed-case unlisted acronym','Port XYZ','Port',NULL,NULL,false,false,'Port XYZ','mixed_case_uppercase_token_preserved',NULL),
    ('unknown symbol only','###','Port',NULL,NULL,false,false,'',NULL,true),
    ('uncertain subdivision not treated as missing','DOVER de','Port','US','DE',true,false,'Dover de',NULL,true),
    -- v2.6. Word-level camel/mixed-case preservation is not dependent on
    -- an otherwise title-cased source; nearby words still use standard rules.
    ('v26 PassNave original case','PassNave TERMINAL','Port',NULL,NULL,false,false,'PassNave Terminal','internal_mixed_case_preserved',NULL),
    ('v26 beachB original case','beachB ANCHORAGE','Anchorage',NULL,NULL,false,false,'beachB Anchorage','internal_mixed_case_preserved',NULL),
    ('v26 BayWa original case','BayWa OFFSHORE TERMINAL','Port',NULL,NULL,false,false,'BayWa Offshore Terminal','internal_mixed_case_preserved',NULL),
    ('v26 McDonald original case','McDonald PORT','Port',NULL,NULL,false,false,'McDonald Port','internal_mixed_case_preserved',NULL),
    ('v26 iPort original case','iPort TERMINAL','Port',NULL,NULL,false,false,'iPort Terminal','internal_mixed_case_preserved',NULL),
    ('v26 internal case amid caps','NORTH PassNave BERTH','Berth',NULL,NULL,false,false,'North PassNave Berth','internal_mixed_case_preserved',NULL),
    ('v26 camel case with hyphen','PassNave-TERMINAL','Port',NULL,NULL,false,false,'PassNave-Terminal','internal_mixed_case_preserved',NULL),
    ('v26 upper PassNave not invented','PASSNAVE TERMINAL','Port',NULL,NULL,false,false,'Passnave Terminal',NULL,NULL),
    ('v26 upper BayWa not invented','BAYWA OFFSHORE TERMINAL','Port',NULL,NULL,false,false,'Baywa Offshore Terminal',NULL,NULL),
    ('v26 odd geographic casing terminal','TeRminal Berth','Berth',NULL,NULL,false,false,'Terminal Berth','geographic_word_recognised',NULL),
    ('v26 odd geographic casing north','NOrTh Berth','Berth',NULL,NULL,false,false,'North Berth','geographic_word_recognised',NULL),
    ('v26 odd minor casing','Port aNd Berth','Port',NULL,NULL,false,false,'Port and Berth','minor_words',NULL),
    ('v26 compass still normalised','NorthWestbound TERMINAL','Port',NULL,NULL,false,false,'Northwestbound Terminal','compass_compounds',NULL),
    ('v26 RoRo dictionary wins','RoRo TERMINAL','Port',NULL,NULL,false,false,'RoRo Terminal','prescribed_maritime_capitalisation',NULL),
    ('v26 legal GmbH wins','HAMBURG SHIPPING GmbH','Port',NULL,NULL,false,false,'Hamburg Shipping GmbH','company_legal_form_prescribed',NULL),
    ('v26 prior DGzRS audit retained','DGzRS - SAR Station Helgoland','Port',NULL,NULL,false,false,'DGzRS - SAR Station Helgoland','mixed_case_internal_acronym_preserved',NULL),
    -- v2.7. Recognised foreign particles retain an already-correct source
    -- spelling, while uppercase text and grammatical phrases still normalise.
    ('v27 Dutch capital De marina','Jachthaven De Uitkijk BV','Marina','NL',NULL,true,false,'Jachthaven De Uitkijk BV','multilingual_particle_case_preserved',NULL),
    ('v27 Dutch lower en marina','Jachthaven en Camping Wijde AA','Marina','NL',NULL,true,false,'Jachthaven en Camping Wijde AA','multilingual_particle_case_preserved',NULL),
    ('v27 German lower und association','Angelsportverein Leer und Umgebung EV','Port','DE',NULL,true,false,'Angelsportverein Leer und Umgebung EV','multilingual_particle_case_preserved',NULL),
    ('v27 Dutch capital De waterway','WSV De Nieuwe Waterweg','Port','NL',NULL,true,false,'WSV De Nieuwe Waterweg','multilingual_particle_case_preserved',NULL),
    ('v27 Dutch De amid uppercase','PORT De Uitkijk','Port','NL',NULL,true,false,'Port De Uitkijk','multilingual_particle_case_preserved',NULL),
    ('v27 German und amid uppercase','PORT und TERMINAL','Port','DE',NULL,true,false,'Port und Terminal',NULL,NULL),
    ('v27 preserve Van and De','Port Van De Rijn','Port','NL',NULL,true,false,'Port Van De Rijn','multilingual_particle_case_preserved',NULL),
    ('v27 preserve lowercase particles','Port van de Rijn','Port','NL',NULL,true,false,'Port van de Rijn','multilingual_particle_case_preserved',NULL),
    ('v27 English and still lower','Port aNd Berth','Port',NULL,NULL,false,false,'Port and Berth','minor_words',NULL),
    ('v27 allcaps Dutch EN lower','JACHTHAVEN EN CAMPING','Marina','NL',NULL,true,false,'Jachthaven en Camping','minor_words',NULL),
    ('v27 allcaps German UND lower','ANGELSPORTVEREIN UND UMGEBUNG','Port','DE',NULL,true,false,'Angelsportverein und Umgebung','minor_words',NULL),
    ('v27 uppercase DE still lower','Port DE Uitkijk','Port','NL',NULL,true,false,'Port de Uitkijk','minor_words',NULL),
    ('v27 uppercase UND still lower','Port UND Berth','Port','DE',NULL,true,false,'Port und Berth','minor_words',NULL),
    ('v27 allcaps French de la','PORT DE LA SELVA','Port','ES',NULL,true,false,'Port de la Selva','minor_words',NULL),
    ('v27 French De la phrase override','Port De la Selva','Port','ES',NULL,true,false,'Port de la Selva','minor_words',NULL),
    ('v27 French de la source lower','Port de la Selva','Port','ES',NULL,true,false,'Port de la Selva',NULL,NULL),
    ('v27 capital De ambiguous language','Quai De France','Port','FR',NULL,true,false,'Quai De France','multilingual_particle_case_preserved',true),
    -- v2.8: preserve uppercase/titlecase source names without overriding
    -- verified geography, prescribed terms or explicit grammatical rules.
    ('v28 OG leading uppercase minor','OG South Berth','Berth',NULL,NULL,false,false,'OG South Berth','existing_mixed_case_name_preserved',false),
    ('v28 AM leading uppercase minor','AM Seven Berth 1','Berth',NULL,NULL,false,false,'AM Seven Berth 1','existing_mixed_case_name_preserved',false),
    ('v28 OG with nonberth type','OG South Area','Port',NULL,NULL,false,false,'OG South Area','existing_mixed_case_name_preserved',false),
    ('v28 OG uppercase inside mixed name','Port OG South Berth','Port',NULL,NULL,false,false,'Port OG South Berth','existing_mixed_case_name_preserved',false),
    ('v28 AM uppercase inside mixed name','Port AM Seven Berth','Port',NULL,NULL,false,false,'Port AM Seven Berth','existing_mixed_case_name_preserved',false),
    ('v28 AM with terminal','AM Seven Terminal','Port',NULL,NULL,false,false,'AM Seven Terminal','existing_mixed_case_name_preserved',false),
    ('v28 long uppercase prefix','ABCDEFGHIJK South Berth','Berth',NULL,NULL,false,false,'ABCDEFGHIJK South Berth','existing_mixed_case_name_preserved',false),
    ('v28 uppercase facility word corrected','PORT South Berth','Port',NULL,NULL,false,false,'Port South Berth','geographic_word_recognised',null),
    ('v28 known geographic casing corrected','CBM TeRminal 1','Berth',NULL,NULL,false,false,'CBM Terminal 1','geographic_word_recognised',null),
    ('v28 prescribed maritime overrides','FSRU Roro Terminal','Terminal',NULL,NULL,false,false,'FSRU RoRo Terminal','prescribed_maritime_capitalisation',null),
    ('v28 Dutch DE still grammatical','Port DE Uitkijk','Port',NULL,NULL,false,false,'Port de Uitkijk','minor_words',null),
    -- v2.9: protect only source-uppercase facility letters and quoted Roman
    -- numerals; do not change English articles or numeric identifier rules.
    ('v29 pier P1 NS dash A East','Pier P1 NS - A East','Pier',NULL,NULL,false,false,'Pier P1 NS - A East','single_letter_facility_identifier_preserved',null),
    ('v29 pier P1 NS dash A West','Pier P1 NS - A West','Pier',NULL,NULL,false,false,'Pier P1 NS - A West','single_letter_facility_identifier_preserved',null),
    ('v29 terminal A NYK','Terminal A NYK Auto','Terminal',NULL,NULL,false,false,'Terminal A NYK Auto','single_letter_facility_identifier_preserved',false),
    ('v29 ALLCAPS terminal A berth','TERMINAL A BERTH','Terminal',NULL,NULL,false,false,'Terminal A Berth','single_letter_facility_identifier_preserved',false),
    ('v29 berth A standalone','Berth A','Berth',NULL,NULL,false,false,'Berth A','single_letter_facility_identifier_preserved',false),
    ('v29 terminal B NYK','Terminal B NYK Auto','Terminal',NULL,NULL,false,false,'Terminal B NYK Auto','single_letter_facility_identifier_preserved',false),
    ('v29 lowercase article after terminal','Terminal a NYK Auto','Terminal',NULL,NULL,false,false,'Terminal a NYK Auto','minor_words',false),
    ('v29 lowercase article after berth','Berth a South','Berth',NULL,NULL,false,false,'Berth a South','minor_words',false),
    ('v29 ordinary article still lowercase','THIS IS A TERMINAL','Port',NULL,NULL,false,false,'This Is a Terminal','minor_words',null),
    ('v29 lowercase A in pier coded phrase','Pier P1 NS - a East','Pier',NULL,NULL,false,false,'Pier P1 NS - a East','minor_words',null),
    ('v29 ambiguous Port A flagged','Port A New Approach','Port',NULL,NULL,false,false,'Port A New Approach','single_letter_facility_identifier_preserved',true),
    ('v29 Port lowercase article stays','Port a New Approach','Port',NULL,NULL,false,false,'Port a New Approach','minor_words',false),
    ('v29 Roman I remains numeral','Terminal I','Terminal',NULL,NULL,false,false,'Terminal I','roman_numerals',false),
    ('v29 Roman V remains numeral','Terminal V','Terminal',NULL,NULL,false,false,'Terminal V','roman_numerals',false),
    ('v29 FSO quoted Roman II', 'FSO ''Federal II''','Port',NULL,NULL,false,false,'FSO ''Federal II''','roman_numerals',false),
    ('v29 quoted Roman IV','PORT ''IV''','Port',NULL,NULL,false,false,'Port ''IV''','roman_numerals',false),
    ('v29 mixedcase quoted Roman Ii','FSO ''Federal Ii''','Port',NULL,NULL,false,false,'FSO ''Federal II''','roman_numerals',false),
    ('v29 quoted Roman III','FSO ''Federal III''','Port',NULL,NULL,false,false,'FSO ''Federal III''','roman_numerals',false),
    ('v29 nonRoman XL quoted unchanged rule','FSO ''Federal XL''','Port',NULL,NULL,false,false,'FSO ''Federal Xl''','apostrophe_casing',false),
    ('v29 possessive apostrophe unchanged','O''Higgins Wharf','Port',NULL,NULL,false,false,'O''Higgins Wharf','apostrophe_casing',false),
    ('v29 No3 identifier now becomes number','No3 0-3LD','Port',NULL,NULL,false,false,'No3 0-3LD','number_followed_by_digits_standardised',false),
    -- v2.10: exact dotted operator branding and exact No+digits spellings.
    ('v210 C.RO company mixed','C.Ro Ports Zeebrugge','Port',NULL,NULL,false,false,'C.RO Ports Zeebrugge','company_brand_prescribed',false),
    ('v210 C.RO company uppercase','C.RO Terminal','Terminal',NULL,NULL,false,false,'C.RO Terminal','company_brand_prescribed',false),
    ('v210 C.RO company lowercase','c.ro Ports Dartford Ltd.','Port',NULL,NULL,false,false,'C.RO Ports Dartford Ltd.','company_brand_prescribed',false),
    ('v210 C.RO source case stable','C.RO Ports London Ltd.','Port',NULL,NULL,false,false,'C.RO Ports London Ltd.','company_brand_prescribed',false),
    ('v210 CRO not a brand','CRO TERMINAL','Terminal',NULL,NULL,false,false,'Cro Terminal',NULL,NULL),
    ('v210 No11 berth','LK South No11 Berth','Berth',NULL,NULL,false,false,'LK South No11 Berth','number_followed_by_digits_standardised',false),
    ('v210 NO7 berth','LK South NO7 Berth','Berth',NULL,NULL,false,false,'LK South No7 Berth','number_followed_by_digits_standardised',false),
    ('v210 NO1 berth','LK South NO1 Berth','Berth',NULL,NULL,false,false,'LK South No1 Berth','number_followed_by_digits_standardised',false),
    ('v210 NO dot 3 berth','BERTH NO.3 East','Berth',NULL,NULL,false,false,'Berth No.3 East','number_followed_by_digits_standardised',false),
    ('v210 no dot 12 berth','Berth no.12 West','Berth',NULL,NULL,false,false,'Berth No.12 West','number_followed_by_digits_standardised',false),
    ('v210 no digits without dot','NO3 0-3LD','Port',NULL,NULL,false,false,'No3 0-3LD','number_followed_by_digits_standardised',false),
    ('v210 number already correct','Berth No.3 East','Berth',NULL,NULL,false,false,'Berth No.3 East','number_followed_by_digits_standardised',false),
    ('v210 Norway NO not a number','NORWAY NO BERTH','Port',NULL,NULL,false,false,'Norway No Berth',NULL,NULL),
    ('v210 identifier NO3A','NO3A Berth','Berth',NULL,NULL,false,false,'NO3A Berth',NULL,false),
    ('v210 separated NO-3 untouched','NO-3 Berth','Berth',NULL,NULL,false,false,'NO-3 Berth',NULL,false),
    ('v210 identifier SB11','SB11 Berth','Berth',NULL,NULL,false,false,'SB11 Berth','alphanumeric_identifier_preserved',false),
    ('v28 confirmed Delaware DE inside name','Dover DE Berth 1','Berth','US','DE',true,true,'Dover DE Berth 1','existing_mixed_case_name_preserved',null),
    ('v28 de la phrase inside mixed guard','OG De la Selva','Port',NULL,NULL,false,false,'OG de la Selva','minor_words',null),
    ('v28 German UND still grammatical','Port UND Berth','Port',NULL,NULL,false,false,'Port und Berth','minor_words',null),
    ('v28 English AND still grammatical','CGAEM South AND North','Port',NULL,NULL,false,false,'CGAEM South and North','minor_words',null),
    ('v28 title-case data unchanged','CGAEM South Outside Berth','Port',NULL,NULL,false,false,'CGAEM South Outside Berth','existing_mixed_case_name_preserved',false),
    ('v28 original lower brand text kept','OG custom South Berth','Berth',NULL,NULL,false,false,'OG custom South Berth','existing_mixed_case_name_preserved',false),
    ('v28 mixed whitespace still cleaned','OG  South Berth','Berth',NULL,NULL,false,false,'OG South Berth','whitespace_normalised',null),
    ('v28 ALLCAPS stays conversion path','OG SOUTH BERTH','Berth',NULL,NULL,false,false,'Og South Berth','first_last_word',null),
    ('v28 no uppercase word','Port am South','Port',NULL,NULL,false,false,'Port am South','multilingual_particle_case_preserved',null),
    ('v28 existing VA remains code','Kinder Morgan SE Terminals Richmond VA Berth 1','Berth',NULL,NULL,false,false,'Kinder Morgan SE Terminals Richmond VA Berth 1','existing_mixed_case_name_preserved',false),
    ('v28 existing mixed company spelling','WSV De Nieuwe Waterweg','Port',NULL,NULL,false,false,'WSV De Nieuwe Waterweg','multilingual_particle_case_preserved',null),
    ('v28 known legal form takes priority','OG Shipping APS','Port',NULL,NULL,false,false,'OG Shipping ApS','company_legal_form_prescribed',null),
    ('v28 no special acronym added ALLCAPS','APO CEMENT TERMINAL','Terminal',NULL,NULL,false,false,'Apo Cement Terminal','allcaps_acronym_candidate',true),
    ('v27 first-word De remains capital','De Nieuwe Haven','Port','NL',NULL,true,false,'De Nieuwe Haven',NULL,NULL),
    ('v27 named De Bilt exception','Jachthaven De Bilt','Marina','NL',NULL,true,false,'Jachthaven De Bilt','proper_name_exceptions',NULL),
    ('region catalogue US AL','TEST al','Port','US','AL',true,true,'Test AL','geographic_abbreviations',NULL),
    ('region catalogue US AK','TEST ak','Port','US','AK',true,true,'Test AK','geographic_abbreviations',NULL),
    ('region catalogue US AZ','TEST az','Port','US','AZ',true,true,'Test AZ','geographic_abbreviations',NULL),
    ('region catalogue US AR','TEST ar','Port','US','AR',true,true,'Test AR','geographic_abbreviations',NULL),
    ('region catalogue US CA','TEST ca','Port','US','CA',true,true,'Test CA','geographic_abbreviations',NULL),
    ('region catalogue US CO','TEST co','Port','US','CO',true,true,'Test CO','geographic_abbreviations',NULL),
    ('region catalogue US CT','TEST ct','Port','US','CT',true,true,'Test CT','geographic_abbreviations',NULL),
    ('region catalogue US DE','TEST de','Port','US','DE',true,true,'Test DE','geographic_abbreviations',NULL),
    ('region catalogue US DC','TEST dc','Port','US','DC',true,true,'Test DC','geographic_abbreviations',NULL),
    ('region catalogue US FL','TEST fl','Port','US','FL',true,true,'Test FL','geographic_abbreviations',NULL),
    ('region catalogue US GA','TEST ga','Port','US','GA',true,true,'Test GA','geographic_abbreviations',NULL),
    ('region catalogue US HI','TEST hi','Port','US','HI',true,true,'Test HI','geographic_abbreviations',NULL),
    ('region catalogue US ID','TEST id','Port','US','ID',true,true,'Test ID','geographic_abbreviations',NULL),
    ('region catalogue US IL','TEST il','Port','US','IL',true,true,'Test IL','geographic_abbreviations',NULL),
    ('region catalogue US IN','TEST in','Port','US','IN',true,true,'Test IN','geographic_abbreviations',NULL),
    ('region catalogue US IA','TEST ia','Port','US','IA',true,true,'Test IA','geographic_abbreviations',NULL),
    ('region catalogue US KS','TEST ks','Port','US','KS',true,true,'Test KS','geographic_abbreviations',NULL),
    ('region catalogue US KY','TEST ky','Port','US','KY',true,true,'Test KY','geographic_abbreviations',NULL),
    ('region catalogue US LA','TEST la','Port','US','LA',true,true,'Test LA','geographic_abbreviations',NULL),
    ('region catalogue US ME','TEST me','Port','US','ME',true,true,'Test ME','geographic_abbreviations',NULL),
    ('region catalogue US MD','TEST md','Port','US','MD',true,true,'Test MD','geographic_abbreviations',NULL),
    ('region catalogue US MA','TEST ma','Port','US','MA',true,true,'Test MA','geographic_abbreviations',NULL),
    ('region catalogue US MI','TEST mi','Port','US','MI',true,true,'Test MI','geographic_abbreviations',NULL),
    ('region catalogue US MN','TEST mn','Port','US','MN',true,true,'Test MN','geographic_abbreviations',NULL),
    ('region catalogue US MS','TEST ms','Port','US','MS',true,true,'Test MS','geographic_abbreviations',NULL),
    ('region catalogue US MO','TEST mo','Port','US','MO',true,true,'Test MO','geographic_abbreviations',NULL),
    ('region catalogue US MT','TEST mt','Port','US','MT',true,true,'Test MT','geographic_abbreviations',NULL),
    ('region catalogue US NE','TEST ne','Port','US','NE',true,true,'Test NE','geographic_abbreviations',NULL),
    ('region catalogue US NV','TEST nv','Port','US','NV',true,true,'Test NV','geographic_abbreviations',NULL),
    ('region catalogue US NH','TEST nh','Port','US','NH',true,true,'Test NH','geographic_abbreviations',NULL),
    ('region catalogue US NJ','TEST nj','Port','US','NJ',true,true,'Test NJ','geographic_abbreviations',NULL),
    ('region catalogue US NM','TEST nm','Port','US','NM',true,true,'Test NM','geographic_abbreviations',NULL),
    ('region catalogue US NY','TEST ny','Port','US','NY',true,true,'Test NY','geographic_abbreviations',NULL),
    ('region catalogue US NC','TEST nc','Port','US','NC',true,true,'Test NC','geographic_abbreviations',NULL),
    ('region catalogue US ND','TEST nd','Port','US','ND',true,true,'Test ND','geographic_abbreviations',NULL),
    ('region catalogue US OH','TEST oh','Port','US','OH',true,true,'Test OH','geographic_abbreviations',NULL),
    ('region catalogue US OK','TEST ok','Port','US','OK',true,true,'Test OK','geographic_abbreviations',NULL),
    ('region catalogue US OR','TEST or','Port','US','OR',true,true,'Test OR','geographic_abbreviations',NULL),
    ('region catalogue US PA','TEST pa','Port','US','PA',true,true,'Test PA','geographic_abbreviations',NULL),
    ('region catalogue US RI','TEST ri','Port','US','RI',true,true,'Test RI','geographic_abbreviations',NULL),
    ('region catalogue US SC','TEST sc','Port','US','SC',true,true,'Test SC','geographic_abbreviations',NULL),
    ('region catalogue US SD','TEST sd','Port','US','SD',true,true,'Test SD','geographic_abbreviations',NULL),
    ('region catalogue US TN','TEST tn','Port','US','TN',true,true,'Test TN','geographic_abbreviations',NULL),
    ('region catalogue US TX','TEST tx','Port','US','TX',true,true,'Test TX','geographic_abbreviations',NULL),
    ('region catalogue US UT','TEST ut','Port','US','UT',true,true,'Test UT','geographic_abbreviations',NULL),
    ('region catalogue US VT','TEST vt','Port','US','VT',true,true,'Test VT','geographic_abbreviations',NULL),
    ('region catalogue US VA','TEST va','Port','US','VA',true,true,'Test VA','geographic_abbreviations',NULL),
    ('region catalogue US WA','TEST wa','Port','US','WA',true,true,'Test WA','geographic_abbreviations',NULL),
    ('region catalogue US WV','TEST wv','Port','US','WV',true,true,'Test WV','geographic_abbreviations',NULL),
    ('region catalogue US WI','TEST wi','Port','US','WI',true,true,'Test WI','geographic_abbreviations',NULL),
    ('region catalogue US WY','TEST wy','Port','US','WY',true,true,'Test WY','geographic_abbreviations',NULL),
    ('region catalogue CA AB','TEST ab','Port','CA','AB',true,true,'Test AB','geographic_abbreviations',NULL),
    ('region catalogue CA BC','TEST bc','Port','CA','BC',true,true,'Test BC','geographic_abbreviations',NULL),
    ('region catalogue CA MB','TEST mb','Port','CA','MB',true,true,'Test MB','geographic_abbreviations',NULL),
    ('region catalogue CA NB','TEST nb','Port','CA','NB',true,true,'Test NB','geographic_abbreviations',NULL),
    ('region catalogue CA NL','TEST nl','Port','CA','NL',true,true,'Test NL','geographic_abbreviations',NULL),
    ('region catalogue CA NT','TEST nt','Port','CA','NT',true,true,'Test NT','geographic_abbreviations',NULL),
    ('region catalogue CA NS','TEST ns','Port','CA','NS',true,true,'Test NS','geographic_abbreviations',NULL),
    ('region catalogue CA NU','TEST nu','Port','CA','NU',true,true,'Test NU','geographic_abbreviations',NULL),
    ('region catalogue CA ON','TEST on','Port','CA','ON',true,true,'Test ON','geographic_abbreviations',NULL),
    ('region catalogue CA PE','TEST pe','Port','CA','PE',true,true,'Test PE','geographic_abbreviations',NULL),
    ('region catalogue CA QC','TEST qc','Port','CA','QC',true,true,'Test QC','geographic_abbreviations',NULL),
    ('region catalogue CA SK','TEST sk','Port','CA','SK',true,true,'Test SK','geographic_abbreviations',NULL),
    ('region catalogue CA YT','TEST yt','Port','CA','YT',true,true,'Test YT','geographic_abbreviations',NULL),
    ('region catalogue AU ACT','TEST act','Port','AU','ACT',true,true,'Test ACT','geographic_abbreviations',NULL),
    ('region catalogue AU NSW','TEST nsw','Port','AU','NSW',true,true,'Test NSW','geographic_abbreviations',NULL),
    ('region catalogue AU NT','TEST nt','Port','AU','NT',true,true,'Test NT','geographic_abbreviations',NULL),
    ('region catalogue AU QLD','TEST qld','Port','AU','QLD',true,true,'Test QLD','geographic_abbreviations',NULL),
    ('region catalogue AU SA','TEST sa','Port','AU','SA',true,true,'Test SA','geographic_abbreviations',NULL),
    ('region catalogue AU TAS','TEST tas','Port','AU','TAS',true,true,'Test TAS','geographic_abbreviations',NULL),
    ('region catalogue AU VIC','TEST vic','Port','AU','VIC',true,true,'Test VIC','geographic_abbreviations',NULL),
    ('region catalogue AU WA','TEST wa','Port','AU','WA',true,true,'Test WA','geographic_abbreviations',NULL)
    ) AS t(test_name,input_name,zone_type_name,country_iso2,regional_abbreviation,
           country_context_ok,region_context_ok,expected_name,required_rule,expect_review)
), tested AS (
    SELECT t.*, f.formatted_name AS actual_name, f.rules_applied,
           f.review_reasons,
           again.formatted_name AS second_pass_name
    FROM test_cases AS t
    CROSS JOIN LATERAL sandbox.zntc_v2_format(
        t.input_name,t.zone_type_name,t.country_iso2,t.regional_abbreviation,
        t.country_context_ok,t.region_context_ok
    ) AS f
    CROSS JOIN LATERAL sandbox.zntc_v2_format(
        f.formatted_name,t.zone_type_name,t.country_iso2,t.regional_abbreviation,
        t.country_context_ok,t.region_context_ok
    ) AS again
)
SELECT t.*,
       t.expected_name IS NOT DISTINCT FROM t.actual_name AS name_passed,
       t.actual_name IS NOT DISTINCT FROM t.second_pass_name AS idempotence_passed,
       (t.required_rule IS NULL OR t.required_rule=ANY(t.rules_applied)) AS rule_flag_passed,
       (t.expect_review IS NULL OR t.expect_review=(cardinality(t.review_reasons)>0)) AS review_flag_passed,
       (t.expected_name IS NOT DISTINCT FROM t.actual_name
        AND t.actual_name IS NOT DISTINCT FROM t.second_pass_name
        AND (t.required_rule IS NULL OR t.required_rule=ANY(t.rules_applied))
        AND (t.expect_review IS NULL OR t.expect_review=(cardinality(t.review_reasons)>0))) AS passed
FROM tested AS t;

-- 11. Installation smoke checks stop the transaction if basic formatting,
-- exact berth protection, multilingual particles or the new source-case guard fail.
-- The full regression suite is available in the validation script.
DO $smoke_tests$
DECLARE v_case record; v_actual text;
BEGIN
    -- v2.8: intentional upper/title-case mixtures must keep source casing,
    -- while confirmed terms and allcaps names still get normalised.
    IF NOT EXISTS (
        SELECT 1 FROM sandbox.zntc_v2_format('OG South Berth','Berth') AS f
        WHERE f.formatted_name='OG South Berth'
          AND 'existing_mixed_case_name_preserved'=ANY(f.rules_applied)
    ) THEN
        RAISE EXCEPTION 'v2.8 smoke check: OG South Berth not protected.';
    END IF;
    IF NOT EXISTS (
        SELECT 1 FROM sandbox.zntc_v2_format('AM Seven Berth 1','Berth') AS f
        WHERE f.formatted_name='AM Seven Berth 1'
          AND 'existing_mixed_case_name_preserved'=ANY(f.rules_applied)
    ) THEN
        RAISE EXCEPTION 'v2.8 smoke check: AM Seven Berth 1 not protected.';
    END IF;
    -- v2.9: exercise the facility label and quoted Roman branches directly.
    IF NOT EXISTS (
        SELECT 1 FROM sandbox.zntc_v2_format('Terminal A NYK Auto','Terminal') AS f
        WHERE f.formatted_name='Terminal A NYK Auto'
          AND 'single_letter_facility_identifier_preserved'=ANY(f.rules_applied)
    ) THEN
        RAISE EXCEPTION 'v2.9 smoke check: Terminal A not preserved.';
    END IF;
    IF NOT EXISTS (
        SELECT 1 FROM sandbox.zntc_v2_format('Pier P1 NS - A East','Pier') AS f
        WHERE f.formatted_name='Pier P1 NS - A East'
          AND 'single_letter_facility_identifier_preserved'=ANY(f.rules_applied)
    ) THEN
        RAISE EXCEPTION 'v2.9 smoke check: pier directional label not preserved.';
    END IF;
    IF NOT EXISTS (
        SELECT 1 FROM sandbox.zntc_v2_format('FSO ''Federal II''','Port') AS f
        WHERE f.formatted_name='FSO ''Federal II'''
          AND 'II'=ANY(f.roman_numerals)
    ) THEN
        RAISE EXCEPTION 'v2.9 smoke check: quoted Roman II lost uppercase.';
    END IF;
    -- V2.10: check the two new branches and protect unrelated identifiers.
    IF NOT EXISTS (
        SELECT 1 FROM sandbox.zntc_v2_format('C.Ro Ports Zeebrugge','Port') AS f
        WHERE f.formatted_name='C.RO Ports Zeebrugge'
          AND 'company_brand_prescribed'=ANY(f.rules_applied)
    ) THEN
        RAISE EXCEPTION 'v2.10 smoke check: C.RO company spelling failed.';
    END IF;
    IF NOT EXISTS (
        SELECT 1 FROM sandbox.zntc_v2_format('LK South NO7 Berth','Berth') AS f
        WHERE f.formatted_name='LK South No7 Berth'
          AND 'number_followed_by_digits_standardised'=ANY(f.rules_applied)
    ) THEN
        RAISE EXCEPTION 'v2.10 smoke check: NO+digits standardisation failed.';
    END IF;
    IF NOT EXISTS (
        SELECT 1 FROM sandbox.zntc_v2_format('BERTH NO.3 East','Berth') AS f
        WHERE f.formatted_name='Berth No.3 East'
          AND 'number_followed_by_digits_standardised'=ANY(f.rules_applied)
    ) THEN
        RAISE EXCEPTION 'v2.10 smoke check: NO.dot+digits standardisation failed.';
    END IF;
    IF (SELECT f.formatted_name FROM sandbox.zntc_v2_format('NO3 0-3LD','Port') AS f)
       IS DISTINCT FROM 'No3 0-3LD' THEN
        RAISE EXCEPTION 'v2.10 smoke check: No3 without punctuation failed.';
    END IF;
    IF (SELECT f.formatted_name FROM sandbox.zntc_v2_format('CRO TERMINAL','Terminal') AS f)
       IS DISTINCT FROM 'Cro Terminal' THEN
        RAISE EXCEPTION 'v2.10 smoke check: undotted CRO was treated as brand.';
    END IF;
    -- v2.7: original source spelling of foreign particles is protected.
    IF (SELECT formatted_name FROM sandbox.zntc_v2_format(
          'Jachthaven De Uitkijk BV','Marina','NL',NULL,true,false))
       IS DISTINCT FROM 'Jachthaven De Uitkijk BV' THEN
        RAISE EXCEPTION 'v2.7 smoke check: Dutch De was not preserved.';
    END IF;
    IF (SELECT formatted_name FROM sandbox.zntc_v2_format(
          'Jachthaven en Camping Wijde AA','Marina','NL',NULL,true,false))
       IS DISTINCT FROM 'Jachthaven en Camping Wijde AA' THEN
        RAISE EXCEPTION 'v2.7 smoke check: Dutch en was not preserved.';
    END IF;
    IF (SELECT formatted_name FROM sandbox.zntc_v2_format(
          'Angelsportverein Leer und Umgebung EV','Port','DE',NULL,true,false))
       IS DISTINCT FROM 'Angelsportverein Leer und Umgebung EV' THEN
        RAISE EXCEPTION 'v2.7 smoke check: German und was not preserved.';
    END IF;
    IF (SELECT formatted_name FROM sandbox.zntc_v2_format('PORT DE LA SELVA','Port'))
       IS DISTINCT FROM 'Port de la Selva' THEN
        RAISE EXCEPTION 'v2.7 smoke check: ALLCAPS de la was not normalised.';
    END IF;
    IF (SELECT formatted_name FROM sandbox.zntc_v2_format('Port De la Selva','Port'))
       IS DISTINCT FROM 'Port de la Selva' THEN
        RAISE EXCEPTION 'v2.7 smoke check: explicit de la phrase did not win.';
    END IF;
    IF (SELECT formatted_name FROM sandbox.zntc_v2_format('SVI Berth 1','Berth')) IS DISTINCT FROM 'SVI Berth 1' THEN
        RAISE EXCEPTION 'V2.3 smoke check failed: preserve SVI Berth 1';
    END IF;
    IF NOT EXISTS (
        SELECT 1 FROM sandbox.zntc_v2_format('SVI Berth 1','Berth') AS f
        WHERE 'mixed_case_berth_pattern_preserved'=ANY(f.rules_applied)
          AND cardinality(f.rules_changed)=0
    ) THEN
        RAISE EXCEPTION 'V2.3 smoke check failed: expected preservation audit';
    END IF;
    IF (SELECT formatted_name FROM sandbox.zntc_v2_format('NORTH Berth 1','Berth')) IS DISTINCT FROM 'North Berth 1' THEN
        RAISE EXCEPTION 'V2.3 smoke check failed: geographical word must not bypass title case';
    END IF;
    -- V2.6: verify mixed-case safeguards and conservative
    -- ALLCAPS conversion rules without reading production zone records.
    IF NOT EXISTS (
        SELECT 1 FROM sandbox.zntc_v2_format('APO CEMENT TERMINAL','Terminal') AS f
        WHERE f.formatted_name='Apo Cement Terminal'
          AND 'allcaps_acronym_candidate'=ANY(f.rules_applied)
    ) THEN
        RAISE EXCEPTION 'V2.6 smoke check failed: ALLCAPS acronym candidate';
    END IF;
    FOR v_case IN SELECT * FROM (VALUES
        ('SINGAPORE ANCH','Anchorage','Singapore Anchorage'),
        ('PORT IV-V','Port','Port IV-V'),
        ('12 BERTH','Berth','Berth 12'),
        ('BANDAR-E LENGEH','Port','Bandar-e Lengeh'),
        ('PORT DE LA SELVA','Port','Port de la Selva'),
        ('O''HIGGINS','Port','O''Higgins'),
        ('SB-1','Berth','SB-1'),
        ('SEA-1','Port','Sea-1'),
        ('FPSO NORTH SEA','Offshore Terminal','FPSO North Sea'),
        ('SVI BERTH 1','Berth','Svi Berth 1'),
        ('CGAEM South Outside Berth','Berth','CGAEM South Outside Berth'),
        ('DGzRS - SAR Station Helgoland','Port','DGzRS - SAR Station Helgoland'),
        ('V&a Marina','Marina','V&A Marina'),
        ('OIL CBM NO 2','Port','Oil CBM No 2'),
        ('RORO TERMINAL','Port','RoRo Terminal'),
        ('RO-RO TERMINAL','Port','Ro-Ro Terminal'),
        ('ROPAX FERRY','Port','RoPax Ferry'),
        ('ATON STATION','Port','AtoN Station'),
        ('MOU AREA','Port','MoU Area'),
        ('FSRU TERMINAL','Offshore Terminal','FSRU Terminal'),
        ('FLNG TERMINAL','Offshore Terminal','FLNG Terminal'),
        ('FSU TERMINAL','Offshore Terminal','FSU Terminal'),
        ('NORDIC SHIPPING APS','Port','Nordic Shipping ApS'),
        ('APS Terminal 1','Terminal','APS Terminal 1'),
        ('HAMBURG SHIPPING GMBH','Port','Hamburg Shipping GmbH'),
        ('POLISH TERMINALS SP. Z O.O.','Port','Polish Terminals sp. z o.o.'),
        ('SINGAPORE PORTS PTE. LTD.','Port','Singapore Ports Pte. Ltd.'),
        ('GLOBAL TERMINALS LLC','Port','Global Terminals LLC'),
        -- v2.6: preserve unknown intra-token case without overriding
        -- ordinary geographical words, compass words, or known forms.
        ('PassNave TERMINAL','Port','PassNave Terminal'),
        ('beachB ANCHORAGE','Anchorage','beachB Anchorage'),
        ('BayWa OFFSHORE TERMINAL','Port','BayWa Offshore Terminal'),
        ('McDonald PORT','Port','McDonald Port'),
        ('iPort TERMINAL','Port','iPort Terminal'),
        ('NORTH PassNave BERTH','Berth','North PassNave Berth'),
        ('TeRminal Berth','Berth','Terminal Berth'),
        ('NOrTh Berth','Berth','North Berth'),
        ('PASSNAVE TERMINAL','Port','Passnave Terminal'),
        ('NorthWestbound TERMINAL','Port','Northwestbound Terminal'),
        -- v2.8: guard high-confidence corrections and ALLCAPS behaviour.
        ('OG South Berth','Berth','OG South Berth'),
        ('AM Seven Berth 1','Berth','AM Seven Berth 1'),
        ('Port OG South Berth','Port','Port OG South Berth'),
        ('Port AM Seven Berth','Port','Port AM Seven Berth'),
        ('OG Shipping APS','Port','OG Shipping ApS'),
        ('Port UND Berth','Port','Port und Berth'),
        ('CGAEM South AND North','Port','CGAEM South and North'),
        ('FSRU Roro Terminal','Port','FSRU RoRo Terminal'),
        ('PORT South Berth','Port','Port South Berth'),
        ('OG SOUTH BERTH','Berth','Og South Berth'),
        -- v2.9: preserve uppercase facility labels without changing articles.
        ('Pier P1 NS - A East','Pier','Pier P1 NS - A East'),
        ('Pier P1 NS - A West','Pier','Pier P1 NS - A West'),
        ('Terminal A NYK Auto','Terminal','Terminal A NYK Auto'),
        ('TERMINAL A BERTH','Terminal','Terminal A Berth'),
        ('Terminal a NYK Auto','Terminal','Terminal a NYK Auto'),
        ('THIS IS A TERMINAL','Port','This Is a Terminal'),
        ('FSO ''Federal II''','Port','FSO ''Federal II'''),
        ('PORT ''IV''','Port','Port ''IV'''),
        ('No3 0-3LD','Port','No3 0-3LD'),
        -- V2.10: two exact branches; existing punctuation is retained.
        ('LK South NO7 Berth','Berth','LK South No7 Berth'),
        ('BERTH NO.3 East','Berth','Berth No.3 East'),
        ('C.Ro Ports Zeebrugge','Port','C.RO Ports Zeebrugge'),
        ('C.RO Ports London Ltd.','Port','C.RO Ports London Ltd.')
    ) AS x(input_name,zone_type_name,expected_name)
    LOOP
        SELECT f.formatted_name INTO v_actual
        FROM sandbox.zntc_v2_format(v_case.input_name,v_case.zone_type_name) AS f;
        IF v_actual IS DISTINCT FROM v_case.expected_name THEN
            RAISE EXCEPTION 'Formatter smoke test failed for %: expected %, got %',
                v_case.input_name,v_case.expected_name,v_actual;
        END IF;
    END LOOP;
END;
$smoke_tests$;

COMMIT;

-- 12. Lightweight completion report verifies the view and formatter
-- exist without scanning every name in the active zones population.
SELECT current_database() AS database_name,
       current_user AS installed_by,
       'sandbox.zone_name_title_case_preview_v2'::text AS preview_view,
       'sandbox.zone_name_title_case_regression_v2'::text AS regression_view,
       'Run zone_name_title_case_validation_v2_10.sql next'::text AS next_step;

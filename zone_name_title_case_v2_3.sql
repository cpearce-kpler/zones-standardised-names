-- ============================================================================
-- ZONE NAME TITLE CASE / AUDITED PREVIEW v2.3
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
-- v2.3: preserve narrowly recognised already-formatted names such as
-- SVI Berth 1 without creating a dictionary of facility-specific acronyms.
-- Retains v2.2 geographical words, maritime acronyms, and identifier rules.
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
        'PLATFORM','PLATFORMS','FACILITY','FACILITIES'
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
        'SPM','MBM','OPL','SWO','LNG','LPG','IMO','AIS','VTS',
        'FSRU','EPO'
    ]::text[];
$maritime$;

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
    ('minor_words','RULE-03','Internal English minor words and explicitly listed foreign particles lowercased.'),
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
    ('geographic_abbreviations','GEOGRAPHY','Contextual country or regional code, or conservative unconfirmed unambiguous suffix.'),
    ('ambiguous_geographic_code_preserved','REVIEW','Uncertain suffix keeps its input spelling; not counted as confirmed geography.'),
    ('compass_compounds','RULE-07','Fused compass words lose internal camel-casing.'),
    ('roman_numerals','RULE-09','Valid Roman numeral tokens I to XXXIX; known grammatical v contexts take priority.'),
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
        'kai','sur','os','au'
    ];
    v_acronyms text[];
    v_maritime_acronyms text[];
    v_geographic_words text[];
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
    v_candidate_reason text;
    v_inverted boolean := false;
    v_n integer;
    v_i integer;
    v_j integer;
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

    -- 8b. Unmatched names use the original V2.2 acronym, geographic-context,
    -- cleaning, foreign-particle and title-case rules without modification.
    v_maritime_acronyms := sandbox.zntc_v2_maritime_acronyms();
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
            v_lookup := replace(v_upper,'.','');
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
            v_protected_identifier :=
                (v_token ~ '^[[:alpha:]]$' AND
                    ((v_after='-' AND coalesce(v_tokens[v_i+1],'') ~ '^[[:alpha:]]$') OR
                     (v_separators[v_i]='-' AND coalesce(v_tokens[v_i-1],'') ~ '^[[:alpha:]]$')))
                OR (v_after='-' AND v_upper=ANY(ARRAY['PL','KS','VP1','W4','E1','M1'])
                                  AND v_next_upper='E')
                OR (v_separators[v_i]='-' AND v_upper='E'
                    AND upper(coalesce(v_tokens[v_i-1],''))=ANY(ARRAY['PL','KS','VP1','W4','E1','M1']))
                OR (v_type IN ('berth','shipyard berth') AND v_upper='A'
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
            ELSIF v_upper='NO' AND (v_next ~ '^[0-9]' OR v_after LIKE '.%') THEN
                v_rule := 'number_abbreviation'; v_new := 'No';
            ELSIF v_lower=ANY(ARRAY['st','appr','co']) AND v_after LIKE '.%' THEN
                v_rule := 'standard_abbreviations'; v_new := initcap(v_lower);
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
            ELSIF v_upper ~ '^(X{0,3})(IX|IV|V?I{0,3})$' AND v_upper<>'' THEN
                v_rule := 'roman_numerals'; v_new := v_upper;
                v_romans := array_append(v_romans,v_upper);
            ELSIF v_lower ~ '^[0-9]+(st|nd|rd|th)$' THEN
                v_rule := 'ordinals'; v_new := v_lower;
            ELSIF v_structured_identifier THEN
                v_rule := 'identifiers'; v_new := v_upper;
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
            ELSE
                v_rule := CASE WHEN v_i=1 OR v_i=v_n THEN 'first_last_word' ELSE 'title_case' END;
                v_new := initcap(v_lower);
            END IF;

            v_events := v_events || jsonb_build_array(jsonb_build_object(
                'rule',v_rule,'before',v_token,'after',v_new,'changed',v_token IS DISTINCT FROM v_new));
            -- Additional orthogonal audit flags: the original acronym/identifier
            -- rules remain visible and these labels identify WHY they applied.
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
               AND v_token ~ '^[A-Z]{2,5}$'
               AND NOT v_upper=ANY(v_geographic_words)
               AND NOT v_lower=ANY(v_minors) THEN
                IF p_name ~ '[a-z]' THEN
                    v_candidate_reason := 'possible_unlisted_acronym:'||v_upper;
                ELSIF v_next_upper=ANY(v_facility_terms)
                   OR upper(coalesce(v_tokens[v_i+2],''))=ANY(v_facility_terms)
                   OR upper(coalesce(v_tokens[v_i+3],''))=ANY(v_facility_terms) THEN
                    v_candidate_reason := 'possible_facility_abbreviation:'||v_upper;
                END IF;
                IF v_candidate_reason IS NOT NULL THEN
                    v_review := array_append(v_review,v_candidate_reason);
                    v_events := v_events || jsonb_build_array(jsonb_build_object(
                        'rule','acronym_review_candidate','before',v_token,
                        'after',v_new,'changed',false,'kind','review_only',
                        'reason',v_candidate_reason));
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
-- 9. PREVIEW INSTALLATION / SOURCE-COLUMN MAPPING (v2.3)
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
               'zone-title-case-v2.3'::text AS formatter_version,
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
                   AS name_short_preserved_mixed_case_berth_pattern
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
    ('non berth zone type','SVI Berth 1','Port',NULL,NULL,false,false,'Svi Berth 1','acronym_review_candidate',true),
    ('extra word not preserved','SVI Berth 1 East','Berth',NULL,NULL,false,false,'Svi Berth 1 East','acronym_review_candidate',true),
    ('long prefix not preserved','ABCDEFG Berth 1','Berth',NULL,NULL,false,false,'Abcdefg Berth 1','geographic_word_recognised',NULL),
    ('multiple spaces not preserved','SVI  Berth 1','Berth',NULL,NULL,false,false,'Svi Berth 1','whitespace_normalised',true),
    ('unknown SVI full-uppercase','SVI BERTH 1','Berth',NULL,NULL,false,false,'Svi Berth 1','acronym_review_candidate',true),
    ('unknown SVI directional','SVI NORTH BERTHING AREA','Berth',NULL,NULL,false,false,'Svi North Berthing Area','acronym_review_candidate',true),
    ('unknown SB standalone','Jiangnan SB 9','Berth',NULL,NULL,false,false,'Jiangnan Sb 9','acronym_review_candidate',true),
    ('ordinary BAY numeric','BAY-1','Port',NULL,NULL,false,false,'Bay-1','geographic_word_recognised',NULL),
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
    ('mixed-case unlisted acronym','Port XYZ','Port',NULL,NULL,false,false,'Port Xyz',NULL,true),
    ('unknown symbol only','###','Port',NULL,NULL,false,false,'',NULL,true),
    ('uncertain subdivision not treated as missing','DOVER de','Port','US','DE',true,false,'Dover de',NULL,true),
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

-- 11. Installation smoke checks stop the transaction if basic formatting
-- or the new exact preservation rule fails. Full tests run separately.
DO $smoke_tests$
DECLARE v_case record; v_actual text;
BEGIN
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
        ('SVI BERTH 1','Berth','Svi Berth 1')
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
       'Run zone_name_title_case_validation_v2_3.sql next'::text AS next_step;

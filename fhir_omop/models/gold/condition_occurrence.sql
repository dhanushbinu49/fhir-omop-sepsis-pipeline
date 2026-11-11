-- OMOP CONDITION_OCCURRENCE: one row per diagnosis, with MIMIC's ICD code swapped for a
-- standard concept (mostly SNOMED). 4,404 rows in the MIMIC demo.
-- Why: ICD-9 '4019' and ICD-10 'I10' are the same disease. Both become 320128
-- 'Essential hypertension', so one query finds them all.

with diagnoses as (
  -- Step 1: add the dot back. MIMIC drops it ('4019'), the vocab keeps it ('401.9').
  -- The dot goes after the 3rd character, except ICD-9 E-codes (after the 4th),
  -- and only if something comes after it.
  select
    condition_id,
    encounter_id,
    code,
    case
      when ends_with(code_system, 'icd10') then 'ICD10CM'
      else 'ICD9CM'
    end                                                        as vocabulary_id,
    -- vocabulary_id can't be used inside this same select, so check code_system again
    case
      when ends_with(code_system, 'icd9') and starts_with(code, 'E') and length(code) > 4
        then concat(substr(code, 1, 4), '.', substr(code, 5))  -- E8497 -> E849.7
      when ends_with(code_system, 'icd9') and starts_with(code, 'E')
        then code                                                -- E887 stays E887
      when length(code) > 3
        then concat(substr(code, 1, 3), '.', substr(code, 4))  -- 4019 -> 401.9, E119 -> E11.9
      else code                                                  -- I10, 311, V08
    end                                                        as code_with_dot
  from {{ ref('stg_condition') }}
),

mapped as (
  -- Step 2: find the ICD concept, then follow 'Maps to' to the standard concept.
  -- Left joins, so a code with no mapping keeps its row (it gets concept 0 below).
  -- A code can map to 2+ standard concepts, which gives 2+ rows (correct in OMOP):
  -- K7031 'Alcoholic cirrhosis of liver with ascites' -> Alcoholic cirrhosis + Ascites due to alcoholic cirrhosis.
  select
    d.condition_id,
    d.encounter_id,
    d.code,
    src.concept_id                                             as source_concept_id,
    std.concept_id                                             as standard_concept_id,
    -- the domain decides which OMOP table a row belongs in: the standard concept's domain,
    -- else the ICD concept's own, else (code not in the vocab at all) keep it as a condition
    coalesce(std.domain_id, src.domain_id, 'Condition')        as domain_id
  from diagnoses as d
  -- always match the vocabulary too: the same text can be a different code in ICD-9 and ICD-10 (E871)
  left join {{ source('vocab', 'concept') }} as src
    on  src.vocabulary_id = d.vocabulary_id
    and src.concept_code  = d.code_with_dot
  left join {{ source('vocab', 'concept_relationship') }} as rel
    on  rel.concept_id_1    = src.concept_id
    and rel.relationship_id = 'Maps to'
    and rel.invalid_reason is null
  left join {{ source('vocab', 'concept') }} as std
    on  std.concept_id       = rel.concept_id_2
    and std.standard_concept = 'S'
    and std.invalid_reason is null
)

-- Step 3: keep only conditions, and take person, visit and dates from the visit.
-- 906 diagnoses aren't conditions in OMOP (V4986 'Do not resuscitate status' is an Observation);
-- they will go to other tables later.
-- MIMIC diagnoses have no date of their own, so a condition starts when its visit starts.
select
  -- one diagnosis can give 2+ rows, so number the rows
  row_number() over (
    order by m.condition_id, coalesce(m.standard_concept_id, 0)
  )                                                            as condition_occurrence_id,
  v.person_id,
  coalesce(m.standard_concept_id, 0)                           as condition_concept_id,
  v.visit_start_date                                           as condition_start_date,
  v.visit_start_datetime                                       as condition_start_datetime,
  cast(null as date)                                           as condition_end_date,           -- MIMIC doesn't say when it ended
  cast(null as datetime)                                       as condition_end_datetime,
  32817                                                        as condition_type_concept_id,    -- EHR
  0                                                            as condition_status_concept_id,
  cast(null as string)                                         as stop_reason,
  cast(null as int64)                                          as provider_id,
  v.visit_occurrence_id,
  cast(null as int64)                                          as visit_detail_id,
  m.code                                                       as condition_source_value,       -- the ICD code as MIMIC has it: '4019'
  coalesce(m.source_concept_id, 0)                             as condition_source_concept_id,  -- the ICD concept: 44821949
  cast(null as string)                                         as condition_status_source_value
from mapped as m
-- left join, so a diagnosis whose visit is missing fails the not_null tests instead of silently disappearing
left join {{ ref('visit_occurrence') }} as v
  on v.visit_source_value = m.encounter_id
where m.domain_id = 'Condition'

with diagnoses as (
  -- MIMIC drops the dot ('4019'), the vocab keeps it ('401.9')
  select
    condition_id,
    encounter_id,
    code,
    case
      when ends_with(code_system, 'icd10') then 'ICD10CM'
      else 'ICD9CM'
    end                                                        as vocabulary_id,
    case
      when ends_with(code_system, 'icd9') and starts_with(code, 'E') and length(code) > 4
        then concat(substr(code, 1, 4), '.', substr(code, 5))
      when ends_with(code_system, 'icd9') and starts_with(code, 'E')
        then code
      when length(code) > 3
        then concat(substr(code, 1, 3), '.', substr(code, 4))
      else code
    end                                                        as code_with_dot
  from {{ ref('stg_condition') }}
),

mapped as (
  select
    d.condition_id,
    d.encounter_id,
    d.code,
    src.concept_id                                             as source_concept_id,
    std.concept_id                                             as standard_concept_id,
    -- the domain decides which OMOP table a row belongs in
    coalesce(std.domain_id, src.domain_id, 'Condition')        as domain_id
  from diagnoses as d
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

-- MIMIC diagnoses have no date, so a condition starts with its visit
select
  row_number() over (
    order by m.condition_id, coalesce(m.standard_concept_id, 0)
  )                                                            as condition_occurrence_id,
  v.person_id,
  coalesce(m.standard_concept_id, 0)                           as condition_concept_id,
  v.visit_start_date                                           as condition_start_date,
  v.visit_start_datetime                                       as condition_start_datetime,
  cast(null as date)                                           as condition_end_date,
  cast(null as datetime)                                       as condition_end_datetime,
  32817                                                        as condition_type_concept_id,    -- EHR
  0                                                            as condition_status_concept_id,
  cast(null as string)                                         as stop_reason,
  cast(null as int64)                                          as provider_id,
  v.visit_occurrence_id,
  cast(null as int64)                                          as visit_detail_id,
  m.code                                                       as condition_source_value,
  coalesce(m.source_concept_id, 0)                             as condition_source_concept_id,
  cast(null as string)                                         as condition_status_source_value
from mapped as m
left join {{ ref('visit_occurrence') }} as v
  on v.visit_source_value = m.encounter_id
where m.domain_id = 'Condition'

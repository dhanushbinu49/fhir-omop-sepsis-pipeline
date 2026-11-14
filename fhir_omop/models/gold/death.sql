select
  subject_id                as person_id,
  death_date,
  datetime(death_date)      as death_datetime,
  32817                     as death_type_concept_id,     -- EHR
  0                         as cause_concept_id,
  cast(null as string)      as cause_source_value,
  0                         as cause_source_concept_id
from {{ ref('stg_patient') }}
where death_date is not null

select
	subject_id as person_id,
	case gender
		when 'female' then 8532
		when 'male' then 8507
		else 0
	end as gender_concept_id,
	EXTRACT(YEAR from birth_date)  as year_of_birth,
	EXTRACT(MONTH from birth_date)  as month_of_birth,
	EXTRACT(DAY from birth_date)  as day_of_birth,
	DATETIME(birth_date) as birth_datetime,
	CASE race_code
		when '2106-3' then 8527
		when '2054-5' then 8516
		else 0
	end as race_concept_id,
	CASE ethnicity_code
		when '2186-5' then 38003564
		when '2135-2' then 38003563
		else 0
	end as ethnicity_concept_id,
	cast(null as int64) as location_id,
	cast(null as int64) as provider_id,
	cast(null as int64) as care_site_id,
	patient_id as person_source_value,
	gender as gender_source_value,
	0 as gender_source_concept_id,
	race_code as race_source_value,
	0 as race_source_concept_id,
	ethnicity_code as ethnicity_source_value,
	0 as ethnicity_source_concept_id
from {{ ref('stg_patient') }}

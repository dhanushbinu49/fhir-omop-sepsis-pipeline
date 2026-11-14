with ingredients as (
	select
		concept_id,
		lower(concept_name) as name
	from {{ source('vocab', 'concept')  }}
	where vocabulary_id = 'RxNorm' AND
		concept_class_id = 'Ingredient' AND
		standard_concept = 'S' AND
		invalid_reason is NULL
),

formulary_names as (
	select
		formulary_code,
		min(drug_name) as drug_name
	from
		{{ ref('stg_medication')  }}
	where formulary_code is not NULL
	group by formulary_code
),

given as (
	select
		a.medication_administration_id as source_id,
		a.patient_id,
		a.encounter_id,
		a.start_datetime,
		a.end_datetime,
		case
			when a.source_file = 'MimicMedicationAdministrationICU.ndjson.gz'
				then a.medication_display
			when ends_with(a.medication_code_system, 'formulary-drug-cd')
				then f.drug_name
			else a.medication_code                       -- eMAR rows whose code is already the drug name
		end as drug_name,
		32818 as drug_type_concept_id,                   -- EHR administration record
		a.dose_value,
		a.dose_unit
	from {{ ref('stg_medication_administration') }} as a
	left join formulary_names as f
		on f.formulary_code = a.medication_code
	where a.method is not null
		and a.method not in ('Not Given', 'Not Flushed', 'Stopped')

	union all

	select
		medication_dispense_id,
		patient_id,
		encounter_id,
		handed_over_datetime,
		cast(null as datetime),
		medication_text,
		32825,                                           -- EHR dispensing record
		cast(null as float64),
		cast(null as string)
	from {{ ref('stg_medication_dispense') }}
	where source_file = 'MimicMedicationDispenseED.ndjson.gz'   -- the other file is pharmacy deliveries, not doses
),

mapped as (
	select
		g.*,
		coalesce(whole.concept_id, two.concept_id, one.concept_id, 0) as drug_concept_id
	from given as g
	left join ingredients as whole
		on whole.name = lower(trim(g.drug_name))
	left join ingredients as two
		on two.name = regexp_extract(lower(trim(g.drug_name)), r'^[a-z]+ [a-z]+')
	left join ingredients as one
		on one.name = regexp_extract(lower(trim(g.drug_name)), r'[a-z]+')
)

select
	row_number() over (order by m.source_id) as drug_exposure_id,
	p.person_id,
	m.drug_concept_id,
	date(m.start_datetime) as drug_exposure_start_date,
	m.start_datetime as drug_exposure_start_datetime,
	date(coalesce(m.end_datetime, m.start_datetime)) as drug_exposure_end_date,
	coalesce(m.end_datetime, m.start_datetime) as drug_exposure_end_datetime,
	cast(null as date) as verbatim_end_date,
	m.drug_type_concept_id,
	cast(null as string) as stop_reason,
	cast(null as int64) as refills,
	m.dose_value as quantity,
	cast(null as int64) as days_supply,
	cast(null as string) as sig,
	0 as route_concept_id,
	cast(null as string) as lot_number,
	cast(null as int64) as provider_id,
	coalesce(vo.visit_occurrence_id, vd.visit_occurrence_id) as visit_occurrence_id,
	vd.visit_detail_id,
	m.drug_name as drug_source_value,
	0 as drug_source_concept_id,
	cast(null as string) as route_source_value,
	m.dose_unit as dose_unit_source_value
from mapped as m
join {{ ref('person') }} as p
	on p.person_source_value = m.patient_id
left join {{ ref('visit_occurrence') }} as vo
	on vo.visit_source_value = m.encounter_id
left join {{ ref('visit_detail') }} as vd
	on vd.visit_detail_source_value = m.encounter_id

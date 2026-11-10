{% macro reference_id(path, column='resource') %} 
 split(json_value({{ column }}, '{{ path }}'), '/')[safe_offset(1)]
{% endmacro %}

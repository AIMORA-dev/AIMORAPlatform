function validate_template(template::ReportTemplate)
    issues = String[]
    isempty(strip(template.id)) && push!(issues, "template id is empty")
    template.version < v"1.0.0" && push!(issues, "template version must be at least 1.0.0")
    isempty(strip(template.licence)) && push!(issues, "template licence is missing")
    isempty(template.required_roles) && push!(issues, "template declares no required section roles")
    isempty(template.output_profiles) && push!(issues, "template declares no output profiles")
    isempty(template.source_hash) && push!(issues, "template source hash is missing")
    !_is_sha256(template.source_hash) && push!(issues, "template source hash is not SHA-256")
    return issues
end

function load_template(path::AbstractString; trusted = false)
    isfile(path) || throw(ArgumentError("template file does not exist: $path"))
    document = TOML.parsefile(path)
    required_keys = ("id", "version", "licence", "family", "required_roles", "output_profiles")
    missing_keys = filter(key -> !haskey(document, key), required_keys)
    isempty(missing_keys) || throw(ArgumentError("template is missing required fields: " * join(missing_keys, ", ")))

    template = ReportTemplate(
        String(document["id"]),
        VersionNumber(document["version"]),
        String(document["licence"]),
        Symbol(document["family"]),
        Symbol.(get(document, "supported_studies", String[])),
        String.(document["required_roles"]),
        Symbol.(document["output_profiles"]),
        Bool(trusted),
        abspath(path),
        _artifact_hash(path),
    )
    issues = validate_template(template)
    isempty(issues) || throw(ArgumentError("invalid report template: " * join(issues, "; ")))
    return template
end

template_hash(template::ReportTemplate) = template.source_hash

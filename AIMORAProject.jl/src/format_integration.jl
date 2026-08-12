const ProjectLoadResult = AIMORAFormats.FormatResult{ProjectRevision}

"""One atomically accepted external import and its complete owner-supplied accounting."""
struct ProjectImportApplication
    revision::ProjectRevision
    plan::AIMORAFormats.ImportPlan
    report::AIMORAFormats.ImportConversionReport
end

Base.:(==)(left::ProjectImportApplication, right::ProjectImportApplication) =
    left.revision == right.revision && left.plan == right.plan && left.report == right.report

const ProjectImportResult = AIMORAFormats.FormatResult{ProjectImportApplication}

struct _ProjectFormatFailure <: Exception
    diagnostic::AIMORAFormats.FormatDiagnostic
end

function _project_format_fail(code::Symbol, message::AbstractString, node::Union{Nothing,AIMORAFormats.FormatNode} = nothing)
    span = isnothing(node) ? nothing : node.span
    throw(_ProjectFormatFailure(AIMORAFormats.FormatDiagnostic(
        AIMORAFormats.DiagnosticError,
        code,
        String(message),
        span,
    )))
end

const _GENERATED_POSITION = AIMORAFormats.SourcePosition(1, 1, 1)
const _GENERATED_SPAN = AIMORAFormats.SourceSpan("<generated-project>", _GENERATED_POSITION, _GENERATED_POSITION)

_format_node(value::AIMORAFormats.FormatValue) = AIMORAFormats.FormatNode(value, _GENERATED_SPAN)
_format_string(value) = _format_node(AIMORAFormats.FormatString(string(value)))
_format_bool(value::Bool) = _format_node(AIMORAFormats.FormatBoolean(value))
_format_integer(value::Integer) = _format_node(AIMORAFormats.FormatInteger(value))
_format_null() = _format_node(AIMORAFormats.FormatNull())

function _format_mapping(pairs::Pair...)
    entries = AIMORAFormats.FormatMappingEntry[
        AIMORAFormats.FormatMappingEntry(_format_string(first(pair)), last(pair)) for pair in pairs
    ]
    return _format_node(AIMORAFormats.FormatMapping(entries))
end

_format_sequence(nodes::AbstractVector{AIMORAFormats.FormatNode}) =
    _format_node(AIMORAFormats.FormatSequence(nodes))

function _mapping_entries(node::AIMORAFormats.FormatNode)
    node.value isa AIMORAFormats.FormatMapping ||
        _project_format_fail(:project_mapping_required, "project value must be a mapping", node)
    return Dict(entry.key.value.value => entry.value for entry in node.value.entries)
end

function _mapping(node::AIMORAFormats.FormatNode, required::AbstractVector{String}, optional::AbstractVector{String} = String[])
    values = _mapping_entries(node)
    admitted = union(Set(required), Set(optional))
    unknown = sort!(collect(setdiff(Set(keys(values)), admitted)))
    isempty(unknown) || _project_format_fail(
        :unknown_project_key,
        "project mapping contains unknown key $(first(unknown))",
        values[first(unknown)],
    )
    missing = sort!(collect(setdiff(Set(required), Set(keys(values)))))
    isempty(missing) || _project_format_fail(
        :missing_project_key,
        "project mapping omits required key $(first(missing))",
        node,
    )
    return values
end

function _sequence(node::AIMORAFormats.FormatNode)
    node.value isa AIMORAFormats.FormatSequence ||
        _project_format_fail(:project_sequence_required, "project value must be a sequence", node)
    return collect(node.value.elements)
end

function _string(node::AIMORAFormats.FormatNode)
    node.value isa AIMORAFormats.FormatString ||
        _project_format_fail(:project_string_required, "project value must be a string", node)
    return node.value.value
end

function _bool(node::AIMORAFormats.FormatNode)
    node.value isa AIMORAFormats.FormatBoolean ||
        _project_format_fail(:project_boolean_required, "project value must be a boolean", node)
    return node.value.value
end

function _integer(node::AIMORAFormats.FormatNode)
    node.value isa AIMORAFormats.FormatInteger ||
        _project_format_fail(:project_integer_required, "project value must be an integer", node)
    return node.value.value
end

_is_null(node::AIMORAFormats.FormatNode) = node.value isa AIMORAFormats.FormatNull

function _enum_string(value::Enum)
    return string(value)
end

function _parse_enum(type::Type{T}, node::AIMORAFormats.FormatNode) where {T<:Enum}
    text = _string(node)
    index = findfirst(value -> string(value) == text, instances(type))
    isnothing(index) && _project_format_fail(
        :unknown_project_enum,
        "$(nameof(type)) has no value $(text)",
        node,
    )
    return instances(type)[index]
end

function _optional(node::AIMORAFormats.FormatNode, operation::F) where {F<:Function}
    return _is_null(node) ? nothing : operation(node)
end

function _exact_scalar_node(value::ExactDecimal)
    return _format_mapping(
        "kind" => _format_string("decimal"),
        "coefficient" => _format_integer(value.coefficient),
        "exponent" => _format_integer(value.exponent),
        "negative_zero" => _format_bool(value.negative_zero),
    )
end

function _exact_scalar_node(value::ExactRational)
    return _format_mapping(
        "kind" => _format_string("rational"),
        "numerator" => _format_integer(value.numerator),
        "denominator" => _format_integer(value.denominator),
        "negative_zero" => _format_bool(value.negative_zero),
    )
end

function _exact_scalar(node::AIMORAFormats.FormatNode)
    values = _mapping_entries(node)
    kind_node = get(values, "kind", nothing)
    isnothing(kind_node) && _project_format_fail(:missing_project_key, "exact scalar omits kind", node)
    kind = _string(kind_node)
    if kind == "decimal"
        values = _mapping(node, ["kind", "coefficient", "exponent", "negative_zero"])
        return ExactDecimal(
            _integer(values["coefficient"]),
            _integer(values["exponent"]);
            negative_zero = _bool(values["negative_zero"]),
        )
    elseif kind == "rational"
        values = _mapping(node, ["kind", "numerator", "denominator", "negative_zero"])
        return ExactRational(
            _integer(values["numerator"]),
            _integer(values["denominator"]);
            negative_zero = _bool(values["negative_zero"]),
        )
    end
    _project_format_fail(:unknown_exact_scalar_kind, "exact scalar kind is unsupported", kind_node)
end

function _licence_node(licence::LicenceIdentity)
    return _format_mapping(
        "id" => _format_string(licence.id),
        "name" => _format_string(licence.name),
        "uri" => isnothing(licence.uri) ? _format_null() : _format_string(licence.uri.uri),
    )
end

function _licence(node::AIMORAFormats.FormatNode)
    values = _mapping(node, ["id", "name", "uri"])
    uri = _optional(values["uri"], item -> GlobalId(_string(item)))
    return LicenceIdentity(_string(values["id"]), _string(values["name"]); uri)
end

function _provenance_node(provenance::ProvenanceSource)
    return _format_mapping(
        "id" => _format_string(provenance.id.value),
        "citation" => _format_string(provenance.citation),
        "source_uri" => isnothing(provenance.source_uri) ? _format_null() : _format_string(provenance.source_uri.uri),
        "source_sha256" => isnothing(provenance.source_sha256) ? _format_null() : _format_string(provenance.source_sha256),
        "source_version" => isnothing(provenance.source_version) ? _format_null() : _format_string(provenance.source_version),
        "licence" => _licence_node(provenance.licence),
    )
end

function _provenance(node::AIMORAFormats.FormatNode)
    values = _mapping(node, ["id", "citation", "source_uri", "source_sha256", "source_version", "licence"])
    return ProvenanceSource(
        ProjectId(_string(values["id"])),
        _string(values["citation"]),
        _licence(values["licence"]);
        source_uri = _optional(values["source_uri"], item -> GlobalId(_string(item))),
        source_sha256 = _optional(values["source_sha256"], _string),
        source_version = _optional(values["source_version"], _string),
    )
end

function _object_identity_node(identity::ObjectIdentity)
    return _format_mapping(
        "id" => _format_string(identity.id.value),
        "uid" => isnothing(identity.uid) ? _format_null() : _format_string(identity.uid.uri),
    )
end

function _object_identity(node::AIMORAFormats.FormatNode)
    values = _mapping(node, ["id", "uid"])
    return ObjectIdentity(
        ProjectId(_string(values["id"]));
        uid = _optional(values["uid"], item -> GlobalId(_string(item))),
    )
end

function _schema_identity_node(identity::SemanticSchemaIdentity)
    return _format_mapping(
        "uuid" => _format_string(identity.uuid),
        "namespace" => _format_string(identity.namespace.value),
        "name" => _format_string(identity.name.value),
        "version" => _format_string(identity.version),
    )
end

function _schema_identity(node::AIMORAFormats.FormatNode)
    values = _mapping(node, ["uuid", "namespace", "name", "version"])
    return SemanticSchemaIdentity(
        UUID(_string(values["uuid"])),
        NamespaceId(_string(values["namespace"])),
        ProjectId(_string(values["name"])),
        VersionNumber(_string(values["version"])),
    )
end

function _semantic_type_node(identity::SemanticTypeId)
    return _format_mapping(
        "namespace" => _format_string(identity.namespace.value),
        "name" => _format_string(identity.name.value),
        "version" => _format_string(identity.version),
    )
end

function _semantic_type(node::AIMORAFormats.FormatNode)
    values = _mapping(node, ["namespace", "name", "version"])
    return SemanticTypeId(
        NamespaceId(_string(values["namespace"])),
        ProjectId(_string(values["name"])),
        VersionNumber(_string(values["version"])),
    )
end

function _dimension_node(dimension::DimensionVector)
    return _format_sequence(AIMORAFormats.FormatNode[
        _format_mapping(
            "numerator" => _format_integer(numerator(exponent)),
            "denominator" => _format_integer(denominator(exponent)),
        ) for exponent in dimension.exponents
    ])
end

function _dimension(node::AIMORAFormats.FormatNode)
    elements = _sequence(node)
    length(elements) == 7 || _project_format_fail(
        :invalid_project_dimension,
        "dimension requires seven SI base exponents",
        node,
    )
    exponents = Rational{Int16}[]
    for element in elements
        values = _mapping(element, ["numerator", "denominator"])
        numerator_value = _integer(values["numerator"])
        denominator_value = _integer(values["denominator"])
        typemin(Int16) <= numerator_value <= typemax(Int16) ||
            _project_format_fail(:invalid_project_dimension, "dimension numerator exceeds Int16", values["numerator"])
        0 < denominator_value <= typemax(Int16) ||
            _project_format_fail(:invalid_project_dimension, "dimension denominator exceeds Int16 or is nonpositive", values["denominator"])
        push!(exponents, Int16(numerator_value) // Int16(denominator_value))
    end
    return DimensionVector(Tuple(exponents))
end

function _reference_node(reference::ProjectReference)
    target_kind = reference.target isa LocalReferenceTarget ? "local" : "global"
    target_id = reference.target isa LocalReferenceTarget ? reference.target.id.value : reference.target.id.uri
    return _format_mapping(
        "kind" => _format_string(_enum_string(reference.kind)),
        "target_kind" => _format_string(target_kind),
        "target" => _format_string(target_id),
        "path" => _format_sequence(AIMORAFormats.FormatNode[_format_string(token.value) for token in reference.path.tokens]),
    )
end

function _reference(node::AIMORAFormats.FormatNode)
    values = _mapping(node, ["kind", "target_kind", "target", "path"])
    kind = _parse_enum(ReferenceKind, values["kind"])
    target_kind = _string(values["target_kind"])
    path = ReferencePath(ReferenceToken[ReferenceToken(_string(item)) for item in _sequence(values["path"])])
    target_kind == "local" && return ProjectReference(kind, ProjectId(_string(values["target"])); path)
    target_kind == "global" && return ProjectReference(kind, GlobalId(_string(values["target"])); path)
    _project_format_fail(:unknown_reference_target_kind, "reference target kind must be local or global", values["target_kind"])
end

function _base_node(base::BaseReference)
    return _format_mapping(
        "kind" => _format_string(_enum_string(base.kind)),
        "reference" => _reference_node(base.reference),
    )
end

function _base_reference(node::AIMORAFormats.FormatNode)
    values = _mapping(node, ["kind", "reference"])
    return BaseReference(_parse_enum(BaseKind, values["kind"]), _reference(values["reference"]))
end

function _quantity_node(quantity::ScalarQuantity)
    return _format_mapping(
        "kind" => _format_string("scalar"),
        "value" => _exact_scalar_node(quantity.value),
        "unit" => _format_string(quantity.unit.value),
        "base" => isnothing(quantity.base) ? _format_null() : _base_node(quantity.base),
        "orientation" => _format_string(_enum_string(quantity.orientation)),
    )
end

function _quantity_node(quantity::ComplexQuantity)
    return _format_mapping(
        "kind" => _format_string("complex"),
        "real" => _exact_scalar_node(quantity.real),
        "imag" => _exact_scalar_node(quantity.imag),
        "unit" => _format_string(quantity.unit.value),
        "base" => isnothing(quantity.base) ? _format_null() : _base_node(quantity.base),
        "orientation" => _format_string(_enum_string(quantity.orientation)),
    )
end

function _quantity(node::AIMORAFormats.FormatNode)
    values = _mapping_entries(node)
    kind_node = get(values, "kind", nothing)
    isnothing(kind_node) && _project_format_fail(:missing_project_key, "quantity omits kind", node)
    kind = _string(kind_node)
    if kind == "scalar"
        values = _mapping(node, ["kind", "value", "unit", "base", "orientation"])
        return ScalarQuantity(
            _exact_scalar(values["value"]),
            UnitId(_string(values["unit"])),
            _optional(values["base"], _base_reference),
            _parse_enum(QuantityOrientation, values["orientation"]),
        )
    elseif kind == "complex"
        values = _mapping(node, ["kind", "real", "imag", "unit", "base", "orientation"])
        return ComplexQuantity(
            _exact_scalar(values["real"]),
            _exact_scalar(values["imag"]),
            UnitId(_string(values["unit"])),
            _optional(values["base"], _base_reference),
            _parse_enum(QuantityOrientation, values["orientation"]),
        )
    end
    _project_format_fail(:unknown_quantity_kind, "quantity kind is unsupported", kind_node)
end

function _uncertainty_node(uncertainty::QuantityUncertainty)
    return _format_mapping(
        "kind" => _format_string(_enum_string(uncertainty.kind)),
        "standard_deviation" => isnothing(uncertainty.standard_deviation) ? _format_null() : _quantity_node(uncertainty.standard_deviation),
        "lower" => isnothing(uncertainty.lower) ? _format_null() : _quantity_node(uncertainty.lower),
        "upper" => isnothing(uncertainty.upper) ? _format_null() : _quantity_node(uncertainty.upper),
        "confidence" => _exact_scalar_node(uncertainty.confidence),
    )
end

function _uncertainty(node::AIMORAFormats.FormatNode)
    values = _mapping(node, ["kind", "standard_deviation", "lower", "upper", "confidence"])
    confidence = _exact_scalar(values["confidence"])
    confidence isa ExactDecimal || _project_format_fail(
        :uncertainty_confidence_decimal_required,
        "uncertainty confidence must be an exact decimal",
        values["confidence"],
    )
    return QuantityUncertainty(
        _parse_enum(UncertaintyKind, values["kind"]),
        confidence;
        standard_deviation = _optional(values["standard_deviation"], item -> begin
            quantity = _quantity(item)
            quantity isa ScalarQuantity || _project_format_fail(:scalar_quantity_required, "uncertainty deviation must be scalar", item)
            quantity
        end),
        lower = _optional(values["lower"], item -> begin
            quantity = _quantity(item)
            quantity isa ScalarQuantity || _project_format_fail(:scalar_quantity_required, "uncertainty lower bound must be scalar", item)
            quantity
        end),
        upper = _optional(values["upper"], item -> begin
            quantity = _quantity(item)
            quantity isa ScalarQuantity || _project_format_fail(:scalar_quantity_required, "uncertainty upper bound must be scalar", item)
            quantity
        end),
    )
end

function _artifact_node(artifact::ArtifactIdentity)
    return _format_mapping(
        "id" => _format_string(artifact.id.value),
        "path" => _format_string(artifact.path),
        "sha256" => _format_string(artifact.sha256),
        "media_type" => _format_string(artifact.media_type),
        "schema" => isnothing(artifact.schema) ? _format_null() : _semantic_type_node(artifact.schema),
        "byte_count" => isnothing(artifact.byte_count) ? _format_null() : _format_integer(artifact.byte_count),
        "provenance" => _provenance_node(artifact.provenance),
    )
end

function _artifact(node::AIMORAFormats.FormatNode)
    values = _mapping(node, ["id", "path", "sha256", "media_type", "schema", "byte_count", "provenance"])
    return ArtifactIdentity(
        ProjectId(_string(values["id"])),
        _string(values["path"]),
        _string(values["sha256"]),
        _string(values["media_type"]),
        _provenance(values["provenance"]);
        schema = _optional(values["schema"], _semantic_type),
        byte_count = _optional(values["byte_count"], _integer),
    )
end

function _canonical_value_node(value::CanonicalFieldData)
    if value isa Bool
        return _format_mapping("kind" => _format_string("boolean"), "value" => _format_bool(value))
    elseif value isa BigInt
        return _format_mapping("kind" => _format_string("integer"), "value" => _format_integer(value))
    elseif value isa ExactDecimal || value isa ExactRational
        return _format_mapping("kind" => _format_string("number"), "value" => _exact_scalar_node(value))
    elseif value isa String
        return _format_mapping("kind" => _format_string("string"), "value" => _format_string(value))
    elseif value isa PhysicalValue
        return _format_mapping(
            "kind" => _format_string("physical"),
            "quantity" => _quantity_node(value.quantity),
            "uncertainty" => isnothing(value.uncertainty) ? _format_null() : _uncertainty_node(value.uncertainty),
            "provenance" => _provenance_node(value.provenance),
        )
    elseif value isa ProjectReference
        return _format_mapping("kind" => _format_string("reference"), "value" => _reference_node(value))
    elseif value isa ArtifactIdentity
        return _format_mapping("kind" => _format_string("artifact"), "value" => _artifact_node(value))
    end
    _semantic_fail(:unsupported_project_field_value, "canonical field value is not admitted by the project format")
end

function _canonical_value(node::AIMORAFormats.FormatNode)
    values = _mapping_entries(node)
    kind_node = get(values, "kind", nothing)
    isnothing(kind_node) && _project_format_fail(:missing_project_key, "canonical value omits kind", node)
    kind = _string(kind_node)
    if kind == "physical"
        values = _mapping(node, ["kind", "quantity", "uncertainty", "provenance"])
        quantity = _quantity(values["quantity"])
        uncertainty = _optional(values["uncertainty"], _uncertainty)
        return PhysicalValue(quantity, _provenance(values["provenance"]); uncertainty)
    end
    values = _mapping(node, ["kind", "value"])
    kind == "boolean" && return _bool(values["value"])
    kind == "integer" && return BigInt(_integer(values["value"]))
    kind == "number" && return _exact_scalar(values["value"])
    kind == "string" && return _string(values["value"])
    kind == "reference" && return _reference(values["value"])
    kind == "artifact" && return _artifact(values["value"])
    _project_format_fail(:unknown_canonical_value_kind, "canonical field value kind is unsupported", kind_node)
end

function _control_task_time(node::AIMORAFormats.FormatNode, label::String)
    value = _canonical_value(node)
    value isa PhysicalValue{ScalarQuantity} || _project_format_fail(
        :control_task_time_quantity_required,
        "$label must be a scalar physical value",
        node,
    )
    return value
end

function _control_task_declaration_node(declaration::ControlTaskDeclaration)
    return _format_mapping(
        "task" => _format_string(declaration.task.value),
        "family" => _format_string(_enum_string(declaration.family)),
        "epoch" => _canonical_value_node(declaration.epoch),
        "period" => _canonical_value_node(declaration.period),
        "phase" => _canonical_value_node(declaration.phase),
        "computational_delay" => _canonical_value_node(declaration.computational_delay),
        "priority" => _format_integer(declaration.priority),
        "read_resources" => _format_sequence(AIMORAFormats.FormatNode[
            _format_string(resource.value) for resource in declaration.read_resources
        ]),
        "write_resources" => _format_sequence(AIMORAFormats.FormatNode[
            _format_string(resource.value) for resource in declaration.write_resources
        ]),
        "predecessors" => _format_sequence(AIMORAFormats.FormatNode[
            _format_string(predecessor.value) for predecessor in declaration.predecessors
        ]),
        "invalidations" => _format_sequence(AIMORAFormats.FormatNode[
            _format_string(_enum_string(effect)) for effect in declaration.invalidations
        ]),
    )
end

function _control_task_declaration(node::AIMORAFormats.FormatNode)
    values = _mapping(node, [
        "task",
        "family",
        "epoch",
        "period",
        "phase",
        "computational_delay",
        "priority",
        "read_resources",
        "write_resources",
        "predecessors",
        "invalidations",
    ])
    return ControlTaskDeclaration(
        ProjectId(_string(values["task"])),
        _parse_enum(ControlTaskFamily, values["family"]),
        _control_task_time(values["epoch"], "control task epoch"),
        _control_task_time(values["period"], "control task period"),
        _control_task_time(values["phase"], "control task phase"),
        _control_task_time(values["computational_delay"], "control task delay");
        priority = _integer(values["priority"]),
        read_resources = ProjectId[
            ProjectId(_string(item)) for item in _sequence(values["read_resources"])
        ],
        write_resources = ProjectId[
            ProjectId(_string(item)) for item in _sequence(values["write_resources"])
        ],
        predecessors = ProjectId[
            ProjectId(_string(item)) for item in _sequence(values["predecessors"])
        ],
        invalidations = ControlTaskInvalidation[
            _parse_enum(ControlTaskInvalidation, item)
            for item in _sequence(values["invalidations"])
        ],
    )
end

function _optional_control_task_time(node::AIMORAFormats.FormatNode, label::String)
    return _optional(node, item -> _control_task_time(item, label))
end

"""Return the versioned inert format node for one exact public control schedule."""
function control_schedule_format_node(schedule::ControlSchedule)
    schedule_node = _format_mapping(
        "domain" => _format_string(_enum_string(schedule.domain)),
        "semantics" => _format_string(_enum_string(schedule.semantics)),
        "sample_time" => isnothing(schedule.sample_time) ?
            _format_null() : _canonical_value_node(schedule.sample_time),
        "phase_offset" => isnothing(schedule.phase_offset) ?
            _format_null() : _canonical_value_node(schedule.phase_offset),
        "computational_delay" => isnothing(schedule.computational_delay) ?
            _format_null() : _canonical_value_node(schedule.computational_delay),
        "task_order" => _format_sequence(AIMORAFormats.FormatNode[
            _format_string(task.value) for task in schedule.task_order
        ]),
        "task_declarations" => _format_sequence(AIMORAFormats.FormatNode[
            _control_task_declaration_node(declaration)
            for declaration in schedule.task_declarations
        ]),
    )
    return _format_mapping(
        "format" => _format_mapping(
            "name" => _format_string("aimora-control-schedule"),
            "version" => _format_string("1.0.0"),
        ),
        "schedule" => schedule_node,
    )
end

function _control_schedule_from_format_node(root::AIMORAFormats.FormatNode)
    values = _mapping(root, ["format", "schedule"])
    format_values = _mapping(values["format"], ["name", "version"])
    _string(format_values["name"]) == "aimora-control-schedule" || _project_format_fail(
        :unknown_control_schedule_format,
        "control schedule format name is unsupported",
        format_values["name"],
    )
    _string(format_values["version"]) == "1.0.0" || _project_format_fail(
        :unknown_control_schedule_format_version,
        "control schedule format version is unsupported",
        format_values["version"],
    )
    schedule_values = _mapping(values["schedule"], [
        "domain",
        "semantics",
        "sample_time",
        "phase_offset",
        "computational_delay",
        "task_order",
        "task_declarations",
    ])
    return ControlSchedule(
        _parse_enum(ControlExecutionDomain, schedule_values["domain"]),
        _parse_enum(ControlSchedulerSemantics, schedule_values["semantics"]),
        ProjectId[
            ProjectId(_string(item)) for item in _sequence(schedule_values["task_order"])
        ];
        sample_time = _optional_control_task_time(
            schedule_values["sample_time"],
            "control schedule sample time",
        ),
        phase_offset = _optional_control_task_time(
            schedule_values["phase_offset"],
            "control schedule phase offset",
        ),
        computational_delay = _optional_control_task_time(
            schedule_values["computational_delay"],
            "control schedule computational delay",
        ),
        task_declarations = ControlTaskDeclaration[
            _control_task_declaration(item)
            for item in _sequence(schedule_values["task_declarations"])
        ],
    )
end

"""Decode one inert control schedule and refuse unknown versions or semantic values."""
function control_schedule_from_format(root::AIMORAFormats.FormatNode)
    try
        return AIMORAFormats.FormatResult{ControlSchedule}(
            _control_schedule_from_format_node(root),
        )
    catch error
        if error isa _ProjectFormatFailure
            return AIMORAFormats.FormatResult{ControlSchedule}(nothing, [error.diagnostic])
        elseif error isa SemanticValidationError
            diagnostic = AIMORAFormats.FormatDiagnostic(
                AIMORAFormats.DiagnosticError,
                error.code,
                error.message,
                root.span,
            )
            return AIMORAFormats.FormatResult{ControlSchedule}(nothing, [diagnostic])
        elseif error isa ArgumentError || error isa MethodError || error isa InexactError
            diagnostic = AIMORAFormats.FormatDiagnostic(
                AIMORAFormats.DiagnosticError,
                :invalid_control_schedule_semantic_value,
                sprint(showerror, error),
                root.span,
            )
            return AIMORAFormats.FormatResult{ControlSchedule}(nothing, [diagnostic])
        end
        rethrow()
    end
end

function _constraint_node(constraint::NumericBoundsConstraint)
    return _format_mapping(
        "kind" => _format_string("numeric_bounds"),
        "lower" => isnothing(constraint.lower) ? _format_null() : _exact_scalar_node(constraint.lower),
        "upper" => isnothing(constraint.upper) ? _format_null() : _exact_scalar_node(constraint.upper),
        "lower_inclusive" => _format_bool(constraint.lower_inclusive),
        "upper_inclusive" => _format_bool(constraint.upper_inclusive),
    )
end

function _constraint_node(constraint::AllowedStringConstraint)
    return _format_mapping(
        "kind" => _format_string("allowed_strings"),
        "values" => _format_sequence(AIMORAFormats.FormatNode[_format_string(value) for value in constraint.values]),
    )
end

function _constraint_node(constraint::QuantityConstraint)
    return _format_mapping(
        "kind" => _format_string("quantity"),
        "dimension" => _dimension_node(constraint.dimension),
        "allow_per_unit" => _format_bool(constraint.allow_per_unit),
        "orientations" => _format_sequence(AIMORAFormats.FormatNode[_format_string(_enum_string(value)) for value in constraint.orientations]),
    )
end

function _constraint_node(constraint::ReferenceConstraint)
    return _format_mapping(
        "kind" => _format_string("reference"),
        "kinds" => _format_sequence(AIMORAFormats.FormatNode[_format_string(_enum_string(value)) for value in constraint.kinds]),
    )
end

function _constraint(node::AIMORAFormats.FormatNode)
    values = _mapping_entries(node)
    kind_node = get(values, "kind", nothing)
    isnothing(kind_node) && _project_format_fail(:missing_project_key, "schema constraint omits kind", node)
    kind = _string(kind_node)
    if kind == "numeric_bounds"
        values = _mapping(node, ["kind", "lower", "upper", "lower_inclusive", "upper_inclusive"])
        return NumericBoundsConstraint(
            lower = _optional(values["lower"], _exact_scalar),
            upper = _optional(values["upper"], _exact_scalar),
            lower_inclusive = _bool(values["lower_inclusive"]),
            upper_inclusive = _bool(values["upper_inclusive"]),
        )
    elseif kind == "allowed_strings"
        values = _mapping(node, ["kind", "values"])
        return AllowedStringConstraint(String[_string(item) for item in _sequence(values["values"])])
    elseif kind == "quantity"
        values = _mapping(node, ["kind", "dimension", "allow_per_unit", "orientations"])
        return QuantityConstraint(
            _dimension(values["dimension"]),
            QuantityOrientation[_parse_enum(QuantityOrientation, item) for item in _sequence(values["orientations"])];
            allow_per_unit = _bool(values["allow_per_unit"]),
        )
    elseif kind == "reference"
        values = _mapping(node, ["kind", "kinds"])
        return ReferenceConstraint(ReferenceKind[_parse_enum(ReferenceKind, item) for item in _sequence(values["kinds"])])
    end
    _project_format_fail(:unknown_schema_constraint, "schema constraint kind is unsupported", kind_node)
end

function _schema_field_node(field::SchemaField)
    return _format_mapping(
        "name" => _format_string(field.name),
        "kind" => _format_string(_enum_string(field.kind)),
        "required" => _format_bool(field.required),
        "constraints" => _format_sequence(AIMORAFormats.FormatNode[_constraint_node(value) for value in field.constraints]),
        "description" => _format_string(field.description),
    )
end

function _schema_field(node::AIMORAFormats.FormatNode)
    values = _mapping(node, ["name", "kind", "required", "constraints", "description"])
    return SchemaField(
        _string(values["name"]),
        _parse_enum(SemanticValueKind, values["kind"]);
        required = _bool(values["required"]),
        constraints = SemanticConstraint[_constraint(item) for item in _sequence(values["constraints"])],
        description = _string(values["description"]),
    )
end

function _schema_node(schema::SemanticSchema)
    return _format_mapping(
        "identity" => _schema_identity_node(schema.identity),
        "fields" => _format_sequence(AIMORAFormats.FormatNode[_schema_field_node(field) for field in schema.fields]),
        "provenance" => _provenance_node(schema.provenance),
    )
end

function _schema(node::AIMORAFormats.FormatNode)
    values = _mapping(node, ["identity", "fields", "provenance"])
    return SemanticSchema(
        _schema_identity(values["identity"]),
        SchemaField[_schema_field(item) for item in _sequence(values["fields"])],
        _provenance(values["provenance"]),
    )
end

function _namespace_node(registration::NamespaceRegistration)
    return _format_mapping(
        "namespace" => _format_string(registration.namespace.value),
        "owner_uuid" => _format_string(registration.owner_uuid),
        "licence" => _licence_node(registration.licence),
        "provenance" => _provenance_node(registration.provenance),
    )
end

function _namespace_registration(node::AIMORAFormats.FormatNode)
    values = _mapping(node, ["namespace", "owner_uuid", "licence", "provenance"])
    return NamespaceRegistration(
        NamespaceId(_string(values["namespace"])),
        UUID(_string(values["owner_uuid"])),
        _licence(values["licence"]),
        _provenance(values["provenance"]),
    )
end

function _unit_node(unit::UnitDefinition)
    return _format_mapping(
        "id" => _format_string(unit.id.value),
        "dimension" => _dimension_node(unit.dimension),
        "scale" => _exact_scalar_node(unit.scale),
        "offset" => _exact_scalar_node(unit.offset),
        "affine_kind" => _format_string(_enum_string(unit.affine_kind)),
        "per_unit" => _format_bool(unit.per_unit),
    )
end

function _unit(node::AIMORAFormats.FormatNode)
    values = _mapping(node, ["id", "dimension", "scale", "offset", "affine_kind", "per_unit"])
    scale = _exact_scalar(values["scale"])
    offset = _exact_scalar(values["offset"])
    scale isa ExactRational || _project_format_fail(:unit_rational_required, "unit scale must be rational", values["scale"])
    offset isa ExactRational || _project_format_fail(:unit_rational_required, "unit offset must be rational", values["offset"])
    return UnitDefinition(
        UnitId(_string(values["id"])),
        _dimension(values["dimension"]),
        scale;
        offset,
        affine_kind = _parse_enum(UnitAffineKind, values["affine_kind"]),
        per_unit = _bool(values["per_unit"]),
    )
end

function _record_node(record::CanonicalRecord)
    fields = AIMORAFormats.FormatNode[
        _format_mapping("name" => _format_string(field.name), "value" => _canonical_value_node(field.value))
        for field in record.fields
    ]
    return _format_mapping(
        "identity" => _object_identity_node(record.identity),
        "schema" => _schema_identity_node(record.schema),
        "fields" => _format_sequence(fields),
        "provenance" => _provenance_node(record.provenance),
    )
end

function _record(node::AIMORAFormats.FormatNode)
    values = _mapping(node, ["identity", "schema", "fields", "provenance"])
    fields = CanonicalField[]
    for field_node in _sequence(values["fields"])
        field_values = _mapping(field_node, ["name", "value"])
        push!(fields, CanonicalField(_string(field_values["name"]), _canonical_value(field_values["value"])))
    end
    return CanonicalRecord(
        _object_identity(values["identity"]),
        _schema_identity(values["schema"]),
        fields,
        _provenance(values["provenance"]),
    )
end

function _project_core_is_serializable(project::CanonicalProject)
    isempty(project.graphs.nodes) && isempty(project.graphs.ports) &&
        isempty(project.graphs.physical_connections) && isempty(project.graphs.signal_connections) &&
        isempty(project.graphs.workflow_dependencies) && isempty(project.graphs.cross_references) &&
        isempty(project.graphs.view_projections) && isempty(project.asset_library.assets) &&
        isempty(project.asset_library.profiles) && isempty(project.asset_library.curves) &&
        isempty(project.asset_library.matrices) && isempty(project.asset_library.measurements) &&
        isempty(project.hierarchy.definitions) && isempty(project.hierarchy.instances) &&
        isempty(project.hierarchy.migrations) && isempty(project.control_system.block_schemas) &&
        isempty(project.control_system.networks) && isempty(project.event_scenarios.events) &&
        isempty(project.event_scenarios.scenarios) && isempty(project.orchestration.study_schemas) &&
        isempty(project.orchestration.studies) && isempty(project.orchestration.result_contracts) &&
        isempty(project.orchestration.results) && isempty(project.orchestration.workflows) &&
        isempty(project.orchestration.experiments)
end

"""Return the complete admitted open-text node for the canonical record-project profile."""
function project_format_node(project::CanonicalProject)
    _project_core_is_serializable(project) || _semantic_fail(
        :project_profile_requires_split_semantic_sections,
        "this compact project profile cannot silently discard graph, asset, hierarchy, control, event, or orchestration sections",
    )
    metadata = project.metadata
    project_node = _format_mapping(
        "identity" => _object_identity_node(metadata.identity),
        "name" => _format_string(metadata.name),
        "default_namespace" => _format_string(metadata.default_namespace.value),
        "format_version" => _format_string(metadata.format_version),
        "created_at_utc" => _format_string(Dates.format(metadata.created_at_utc, dateformat"yyyy-mm-ddTHH:MM:SS.s")),
        "provenance" => _provenance_node(metadata.provenance),
    )
    return _format_mapping(
        "format" => _format_mapping(
            "name" => _format_string("aimora-project"),
            "version" => _format_string("1.0.0"),
        ),
        "project" => project_node,
        "namespaces" => _format_sequence(AIMORAFormats.FormatNode[_namespace_node(item) for item in project.registry.namespaces]),
        "schemas" => _format_sequence(AIMORAFormats.FormatNode[_schema_node(item) for item in project.registry.schemas]),
        "units" => _format_sequence(AIMORAFormats.FormatNode[_unit_node(item) for item in project.units.units]),
        "records" => _format_sequence(AIMORAFormats.FormatNode[_record_node(item) for item in project.records]),
    )
end

function _project_from_format_node(root::AIMORAFormats.FormatNode)
    values = _mapping(root, ["format", "project", "namespaces", "schemas", "units", "records"])
    format_values = _mapping(values["format"], ["name", "version"])
    _string(format_values["name"]) == "aimora-project" || _project_format_fail(
        :unknown_project_format,
        "project format name must be aimora-project",
        format_values["name"],
    )
    _string(format_values["version"]) == "1.0.0" || _project_format_fail(
        :unknown_project_format_version,
        "project format version is unsupported",
        format_values["version"],
    )
    metadata_values = _mapping(
        values["project"],
        ["identity", "name", "default_namespace", "format_version", "created_at_utc", "provenance"],
    )
    metadata = ProjectMetadata(
        _object_identity(metadata_values["identity"]),
        _string(metadata_values["name"]),
        NamespaceId(_string(metadata_values["default_namespace"])),
        VersionNumber(_string(metadata_values["format_version"])),
        DateTime(_string(metadata_values["created_at_utc"])),
        _provenance(metadata_values["provenance"]),
    )
    registry = SemanticSchemaRegistry(
        NamespaceRegistration[_namespace_registration(item) for item in _sequence(values["namespaces"])],
        SemanticSchema[_schema(item) for item in _sequence(values["schemas"])],
    )
    units = UnitRegistry(UnitDefinition[_unit(item) for item in _sequence(values["units"])])
    records = CanonicalRecord[_record(item) for item in _sequence(values["records"])]
    return CanonicalProject(metadata, registry, units, records)
end

"""Decode and semantically validate one resolved format node without executing project data."""
function project_from_format(root::AIMORAFormats.FormatNode)
    try
        project = _project_from_format_node(root)
        return AIMORAFormats.FormatResult{CanonicalProject}(project)
    catch error
        if error isa _ProjectFormatFailure
            return AIMORAFormats.FormatResult{CanonicalProject}(nothing, [error.diagnostic])
        elseif error isa SemanticValidationError
            diagnostic = AIMORAFormats.FormatDiagnostic(
                AIMORAFormats.DiagnosticError,
                error.code,
                error.message,
                root.span,
            )
            return AIMORAFormats.FormatResult{CanonicalProject}(nothing, [diagnostic])
        elseif error isa ArgumentError || error isa MethodError || error isa InexactError
            diagnostic = AIMORAFormats.FormatDiagnostic(
                AIMORAFormats.DiagnosticError,
                :invalid_project_semantic_value,
                sprint(showerror, error),
                root.span,
            )
            return AIMORAFormats.FormatResult{CanonicalProject}(nothing, [diagnostic])
        end
        rethrow()
    end
end

function _revision_provenance_for_open(project::CanonicalProject)
    return RevisionProvenance(
        ProjectId("action.open_project"),
        project.metadata.created_at_utc,
        project.metadata.provenance,
    )
end

"""Open a compact or directory project through AIMORAFormats and return an exact initial revision."""
function open_project(path::AbstractString; policy::AIMORAFormats.ProjectResolutionPolicy = AIMORAFormats.ProjectResolutionPolicy())
    resolved = AIMORAFormats.resolve_project_documents(path; policy)
    AIMORAFormats.format_succeeded(resolved) ||
        return ProjectLoadResult(nothing, collect(resolved.diagnostics))
    decoded = project_from_format(resolved.value.root)
    AIMORAFormats.format_succeeded(decoded) ||
        return ProjectLoadResult(nothing, collect(decoded.diagnostics))
    project = decoded.value
    revision = initial_revision(
        project,
        ContentDigest(resolved.value.source_sha256),
        project_resolved_hash(project),
        _revision_provenance_for_open(project),
    )
    return ProjectLoadResult(revision, collect(decoded.diagnostics))
end

function validate_project(path::AbstractString; policy::AIMORAFormats.ProjectResolutionPolicy = AIMORAFormats.ProjectResolutionPolicy())
    return open_project(path; policy)
end

"""Return deterministic canonical JSON for one semantically decoded project path."""
function normalize_project(path::AbstractString; policy::AIMORAFormats.ProjectResolutionPolicy = AIMORAFormats.ProjectResolutionPolicy())
    opened = open_project(path; policy)
    AIMORAFormats.format_succeeded(opened) ||
        return AIMORAFormats.FormatSerializationResult(nothing, collect(opened.diagnostics))
    return AIMORAFormats.serialize_canonical_json(project_format_node(opened.value.project); policy = policy.format_policy)
end

function _write_project_bytes(path::String, bytes::Vector{UInt8}; overwrite::Bool)
    ispath(path) && !overwrite && _semantic_fail(:project_output_exists, "project output already exists")
    directory = dirname(path)
    isdir(directory) || mkpath(directory)
    temporary, stream = mktemp(directory; cleanup = false)
    try
        write(stream, bytes)
        flush(stream)
        close(stream)
        mv(temporary, path; force = overwrite)
    catch
        isopen(stream) && close(stream)
        isfile(temporary) && Base.Filesystem.unlink(temporary)
        rethrow()
    end
    return path
end

"""Save one compact file or directory-root project using restricted YAML and atomic replacement."""
function save_project(
    path::AbstractString,
    project::CanonicalProject;
    overwrite::Bool = false,
    policy::AIMORAFormats.FormatInputPolicy = AIMORAFormats.FormatInputPolicy(),
)
    node = project_format_node(project)
    serialized = AIMORAFormats.serialize_restricted_yaml(node; policy)
    AIMORAFormats.format_succeeded(serialized) || return serialized
    requested = abspath(String(path))
    destination = endswith(lowercase(requested), ".aimora.yaml") ? requested : joinpath(requested, "project.aimora.yaml")
    _write_project_bytes(destination, collect(serialized.value.bytes); overwrite)
    return serialized
end

function _same_project_foundation(left::CanonicalProject, right::CanonicalProject)
    return left.metadata.identity == right.metadata.identity &&
        left.metadata.default_namespace == right.metadata.default_namespace &&
        left.metadata.format_version == right.metadata.format_version &&
        left.metadata.created_at_utc == right.metadata.created_at_utc &&
        left.metadata.provenance == right.metadata.provenance &&
        left.registry == right.registry && left.units == right.units &&
        left.graphs == right.graphs && left.asset_library == right.asset_library &&
        left.hierarchy == right.hierarchy && left.control_system == right.control_system &&
        left.event_scenarios == right.event_scenarios && left.orchestration == right.orchestration
end

"""Convert a project document into deterministic commands against one exact accepted base."""
function commands_from_format(base::ProjectRevision, root::AIMORAFormats.FormatNode)
    decoded = project_from_format(root)
    AIMORAFormats.format_succeeded(decoded) || return AIMORAFormats.FormatResult{CanonicalList{ProjectCommand}}(
        nothing,
        collect(decoded.diagnostics),
    )
    target = decoded.value
    _same_project_foundation(base.project, target) || begin
        diagnostic = AIMORAFormats.FormatDiagnostic(
            AIMORAFormats.DiagnosticError,
            :unsupported_project_foundation_change,
            "format-to-command conversion cannot replace schema, unit, identity, or non-record graph owners",
            root.span,
        )
        return AIMORAFormats.FormatResult{CanonicalList{ProjectCommand}}(nothing, [diagnostic])
    end
    commands = ProjectCommand[]
    counter = 1
    next_id(action) = ProjectId("command.format.$(action)_c$(counter += 1)")
    if base.project.metadata.name != target.metadata.name
        push!(commands, ProjectCommand(next_id("set_project_name"), SetProjectNamePatch(target.metadata.name)))
    end
    base_by_id = Dict(record.identity.id => record for record in base.project.records)
    target_by_id = Dict(record.identity.id => record for record in target.records)
    for owner in sort!(collect(setdiff(Set(keys(base_by_id)), Set(keys(target_by_id)))); by = item -> item.value)
        push!(commands, ProjectCommand(next_id("remove_record"), RemoveRecordPatch(owner)))
    end
    for owner in sort!(collect(keys(target_by_id)); by = item -> item.value)
        target_record = target_by_id[owner]
        if !haskey(base_by_id, owner)
            push!(commands, ProjectCommand(next_id("add_record"), AddRecordPatch(target_record)))
            continue
        end
        base_record = base_by_id[owner]
        base_record.identity == target_record.identity && base_record.schema == target_record.schema &&
            base_record.provenance == target_record.provenance || begin
            diagnostic = AIMORAFormats.FormatDiagnostic(
                AIMORAFormats.DiagnosticError,
                :unsupported_record_owner_change,
                "format-to-command conversion cannot replace record identity, schema, or provenance",
                root.span,
            )
            return AIMORAFormats.FormatResult{CanonicalList{ProjectCommand}}(nothing, [diagnostic])
        end
        base_fields = Dict(field.name => field for field in base_record.fields)
        target_fields = Dict(field.name => field for field in target_record.fields)
        for name in sort!(collect(setdiff(Set(keys(base_fields)), Set(keys(target_fields)))))
            push!(commands, ProjectCommand(next_id("unset_record_field"), UnsetRecordFieldPatch(owner, name)))
        end
        for name in sort!(collect(keys(target_fields)))
            haskey(base_fields, name) && base_fields[name] == target_fields[name] && continue
            push!(commands, ProjectCommand(next_id("set_record_field"), SetRecordFieldPatch(owner, target_fields[name])))
        end
    end
    return AIMORAFormats.FormatResult(CanonicalList{ProjectCommand}(commands))
end

function _schema_for_import(registry::SemanticSchemaRegistry, object_type::String)
    matches = SemanticSchema[
        schema for schema in registry.schemas
        if schema.identity.name.value == object_type ||
            string(schema.identity.namespace.value, '.', schema.identity.name.value) == object_type
    ]
    length(matches) == 1 || _semantic_fail(
        isempty(matches) ? :unknown_import_object_type : :ambiguous_import_object_type,
        "import object type must resolve to exactly one semantic schema",
    )
    return only(matches)
end

function _import_scalar(node::AIMORAFormats.FormatNode, field::SchemaField)
    value = node.value
    value isa AIMORAFormats.FormatNull && _semantic_fail(:null_import_field, "import assignment cannot map null into a canonical field")
    if field.kind == SchemaBoolean && value isa AIMORAFormats.FormatBoolean
        return value.value
    elseif field.kind == SchemaInteger && value isa AIMORAFormats.FormatInteger
        return BigInt(value.value)
    elseif field.kind == SchemaDecimal
        value isa AIMORAFormats.FormatInteger && return ExactDecimal(value.value, 0)
        value isa AIMORAFormats.FormatDecimal && return ExactDecimal(value.coefficient, value.exponent; negative_zero = value.negative_zero)
    elseif field.kind == SchemaString && value isa AIMORAFormats.FormatString
        return value.value
    end
    _semantic_fail(:import_field_type_mismatch, "import scalar kind differs from its destination schema field")
end

function _import_destination_field(
    operation::AIMORAFormats.ImportFieldAssignment,
    schema::SemanticSchema,
)
    segments = collect(operation.destination.segments)
    !isempty(segments) && all(segment -> segment isa AIMORAFormats.FormatMappingKeySegment, segments) ||
        _semantic_fail(:unsupported_import_destination, "canonical record import requires mapping-key field destinations")
    keys = String[segment.key for segment in segments]
    candidates = unique(vcat([join(keys, "__"), join(keys, "_")], [last(keys)]))
    declared = Set(field.name for field in schema.fields)
    matches = String[candidate for candidate in candidates if candidate in declared]
    length(matches) == 1 || _semantic_fail(
        isempty(matches) ? :unknown_import_destination : :ambiguous_import_destination,
        "import destination must resolve to exactly one declared canonical field",
    )
    return only(matches)
end

"""Apply one complete inert import plan through a single all-or-nothing project transaction."""
function apply_import_plan(
    base::ProjectRevision,
    imported::AIMORAFormats.GenericImportResult;
    provenance::RevisionProvenance,
    field_provenance::ProvenanceSource = provenance.source,
)
    plan = imported.plan
    report = imported.report
    if !plan.applicable || !report.complete
        diagnostic = AIMORAFormats.FormatDiagnostic(
            AIMORAFormats.DiagnosticError,
            :blocked_import_plan,
            "import plan contains rejected or unsupported source fields",
        )
        return ProjectImportResult(nothing, [diagnostic])
    end
    try
        creates = Dict{String,AIMORAFormats.ImportCreateObject}()
        assignments = Dict{String,Vector{AIMORAFormats.ImportFieldAssignment}}()
        for operation in plan.operations
            if operation isa AIMORAFormats.ImportCreateObject
                haskey(creates, operation.object_id) && _semantic_fail(:duplicate_import_object, "import plan creates one object more than once")
                creates[operation.object_id] = operation
            elseif operation isa AIMORAFormats.ImportFieldAssignment
                push!(get!(assignments, operation.object_id, AIMORAFormats.ImportFieldAssignment[]), operation)
            else
                _semantic_fail(:unknown_import_operation, "import plan contains an unsupported operation type")
            end
        end
        setdiff(Set(keys(assignments)), Set(keys(creates))) |> isempty ||
            _semantic_fail(:import_assignment_without_object, "import plan assigns a field to an object it does not create")
        records = CanonicalRecord[]
        for object_id in sort!(collect(keys(creates)))
            creation = creates[object_id]
            schema = _schema_for_import(base.project.registry, creation.object_type)
            fields = CanonicalField[]
            if any(field -> field.name == "id", schema.fields)
                id_field = schema_field(schema, "id")
                id_field.kind == SchemaString || _semantic_fail(
                    :import_identity_schema_mismatch,
                    "canonical import identity field must be a string",
                )
                push!(fields, CanonicalField("id", object_id))
            end
            seen = Set{String}()
            for assignment in sort!(get(assignments, object_id, AIMORAFormats.ImportFieldAssignment[]); by = item -> sprint(show, item.destination))
                name = _import_destination_field(assignment, schema)
                name == "id" && continue
                name in seen && _semantic_fail(:duplicate_import_destination, "import plan repeats one canonical destination field")
                push!(seen, name)
                declared = schema_field(schema, name)
                push!(fields, CanonicalField(name, _import_scalar(assignment.value, declared)))
            end
            record = CanonicalRecord(
                ObjectIdentity(ProjectId(object_id)),
                schema.identity,
                fields,
                field_provenance,
            )
            _validate_record(base.project, record)
            push!(records, record)
        end
        builder = project_builder(base)
        for record in sort!(records; by = item -> item.identity.id.value)
            add_record!(builder, record)
        end
        revision = commit_builder!(
            builder;
            source_hash = ContentDigest(plan.source_sha256),
            provenance,
        )
        return ProjectImportResult(ProjectImportApplication(revision, plan, report))
    catch error
        if error isa SemanticValidationError
            diagnostic = AIMORAFormats.FormatDiagnostic(
                AIMORAFormats.DiagnosticError,
                error.code,
                error.message,
            )
            return ProjectImportResult(nothing, [diagnostic])
        end
        rethrow()
    end
end

function migrate_aimora_project_v1(
    base::ProjectRevision,
    source;
    provenance::RevisionProvenance,
    field_provenance::ProvenanceSource = provenance.source,
    policy::AIMORAFormats.FormatInputPolicy = AIMORAFormats.FormatInputPolicy(),
)
    imported = AIMORAFormats.read_aimora_project_v1(source; policy)
    AIMORAFormats.format_succeeded(imported) ||
        return ProjectImportResult(nothing, collect(imported.diagnostics))
    return apply_import_plan(base, imported.value; provenance, field_provenance)
end

function migrate_aimora_asset_csv(
    base::ProjectRevision,
    source,
    schema::AIMORAFormats.BulkTableSchema,
    object_type::AbstractString,
    object_namespace::AbstractString,
    rules::AbstractVector{AIMORAFormats.ImportFieldRule};
    provenance::RevisionProvenance,
    field_provenance::ProvenanceSource = provenance.source,
    assumptions::AbstractVector{AIMORAFormats.ImportAssumption} = AIMORAFormats.ImportAssumption[],
    policy::AIMORAFormats.FormatInputPolicy = AIMORAFormats.FormatInputPolicy(),
)
    imported = AIMORAFormats.read_aimora_asset_csv(
        source,
        schema,
        object_type,
        object_namespace,
        rules;
        assumptions,
        policy,
    )
    AIMORAFormats.format_succeeded(imported) ||
        return ProjectImportResult(nothing, collect(imported.diagnostics))
    return apply_import_plan(base, imported.value; provenance, field_provenance)
end

function migrate_aimora_catalog_entry_v1(
    base::ProjectRevision,
    source;
    provenance::RevisionProvenance,
    field_provenance::ProvenanceSource = provenance.source,
    policy::AIMORAFormats.FormatInputPolicy = AIMORAFormats.FormatInputPolicy(),
)
    imported = AIMORAFormats.read_aimora_catalog_entry_v1(source; policy)
    AIMORAFormats.format_succeeded(imported) ||
        return ProjectImportResult(nothing, collect(imported.diagnostics))
    return apply_import_plan(base, imported.value; provenance, field_provenance)
end

function migrate_aimora_cases_catalog_v2(
    base::ProjectRevision,
    source;
    provenance::RevisionProvenance,
    field_provenance::ProvenanceSource = provenance.source,
    available_paths::Union{Nothing,AbstractSet{<:AbstractString}} = nothing,
    policy::AIMORAFormats.FormatInputPolicy = AIMORAFormats.FormatInputPolicy(),
)
    imported = AIMORAFormats.read_aimora_cases_catalog_v2(
        source;
        available_paths,
        policy,
    )
    AIMORAFormats.format_succeeded(imported) ||
        return ProjectImportResult(nothing, collect(imported.diagnostics))
    return apply_import_plan(base, imported.value; provenance, field_provenance)
end

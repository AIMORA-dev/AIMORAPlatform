"""A stable package function identity; no closure, source text, or executable value is stored."""
struct RegisteredFunctionIdentity
    package_uuid::UUID
    package::SemanticTypeId
    symbol::ProjectId
    content_hash::ContentDigest
end

Base.:(==)(left::RegisteredFunctionIdentity, right::RegisteredFunctionIdentity) =
    left.package_uuid == right.package_uuid && left.package == right.package &&
    left.symbol == right.symbol && left.content_hash == right.content_hash

@enum StudyOutsideDomainPolicy::UInt8 begin
    StudyOutsideDomainError = 0x01
    StudyOutsideDomainWarning = 0x02
end

@enum StudyOptionalDataPolicy::UInt8 begin
    StudyOptionalDataIgnore = 0x01
    StudyOptionalDataWarning = 0x02
end

struct StudyValidityPolicy
    outside_domain::StudyOutsideDomainPolicy
    missing_optional_data::StudyOptionalDataPolicy
end

Base.:(==)(left::StudyValidityPolicy, right::StudyValidityPolicy) =
    left.outside_domain == right.outside_domain &&
    left.missing_optional_data == right.missing_optional_data

"""One versioned owner-specific study request contract."""
struct StudyRequestSchema
    identity::SemanticSchemaIdentity
    representations::CanonicalList{ModelRepresentation}
    fidelities::CanonicalList{ModelFidelity}
    settings::CanonicalList{SchemaField}
    initialization::CanonicalList{SchemaField}
    provenance::ProvenanceSource

    function StudyRequestSchema(
        identity::SemanticSchemaIdentity,
        representations::AbstractVector{ModelRepresentation},
        fidelities::AbstractVector{ModelFidelity},
        settings::AbstractVector{SchemaField},
        initialization::AbstractVector{SchemaField},
        provenance::ProvenanceSource,
    )
        representation_copy = sort!(collect(representations); by = UInt8)
        fidelity_copy = sort!(collect(fidelities); by = UInt8)
        isempty(representation_copy) &&
            _semantic_fail(:missing_study_representation, "study schema requires a representation")
        isempty(fidelity_copy) &&
            _semantic_fail(:missing_study_fidelity, "study schema requires a fidelity")
        length(representation_copy) == length(unique(representation_copy)) ||
            _semantic_fail(:duplicate_study_representation, "study schema repeats a representation")
        length(fidelity_copy) == length(unique(fidelity_copy)) ||
            _semantic_fail(:duplicate_study_fidelity, "study schema repeats a fidelity")
        setting_copy = sort!(collect(settings); by = item -> item.name)
        initialization_copy = sort!(collect(initialization); by = item -> item.name)
        setting_names = getfield.(setting_copy, :name)
        initialization_names = getfield.(initialization_copy, :name)
        length(setting_names) == length(unique(setting_names)) ||
            _semantic_fail(:duplicate_study_setting_schema, "study schema repeats a setting")
        length(initialization_names) == length(unique(initialization_names)) ||
            _semantic_fail(:duplicate_study_initialization_schema, "study schema repeats an initialization field")
        isempty(intersect(Set(setting_names), Set(initialization_names))) ||
            _semantic_fail(:study_field_role_collision, "study field cannot be both setting and initialization")
        return new(
            identity,
            CanonicalList{ModelRepresentation}(representation_copy),
            CanonicalList{ModelFidelity}(fidelity_copy),
            CanonicalList{SchemaField}(setting_copy),
            CanonicalList{SchemaField}(initialization_copy),
            provenance,
        )
    end
end

Base.:(==)(left::StudyRequestSchema, right::StudyRequestSchema) =
    left.identity == right.identity && left.representations == right.representations &&
    left.fidelities == right.fidelities && left.settings == right.settings &&
    left.initialization == right.initialization && left.provenance == right.provenance

struct StudyMethodDeclaration
    method::SemanticTypeId
    implementation::RegisteredFunctionIdentity
    options::CanonicalList{CanonicalField}

    function StudyMethodDeclaration(
        method::SemanticTypeId,
        implementation::RegisteredFunctionIdentity,
        options::AbstractVector{CanonicalField},
    )
        copied = sort!(collect(options); by = item -> item.name)
        names = getfield.(copied, :name)
        length(names) == length(unique(names)) ||
            _semantic_fail(:duplicate_study_method_option, "study method repeats an option")
        return new(method, implementation, CanonicalList{CanonicalField}(copied))
    end
end

Base.:(==)(left::StudyMethodDeclaration, right::StudyMethodDeclaration) =
    left.method == right.method && left.implementation == right.implementation &&
    left.options == right.options

"""One typed output selection which names its result contract before execution."""
struct StudyOutputRequest
    identity::ObjectIdentity
    contract::SemanticSchemaIdentity
    target::ProjectReference
    quantity::SemanticTypeId
    unit::UnitId
    orientation::QuantityOrientation
    provenance::ProvenanceSource
end

Base.:(==)(left::StudyOutputRequest, right::StudyOutputRequest) =
    left.identity == right.identity && left.contract == right.contract &&
    left.target == right.target && left.quantity == right.quantity &&
    left.unit == right.unit && left.orientation == right.orientation &&
    left.provenance == right.provenance

"""An explicit study prerequisite; automatic computation is never inferred."""
struct StudyPrerequisite
    identity::ObjectIdentity
    upstream::ProjectReference
    automatic::Bool
    required_contract::SemanticSchemaIdentity
    provenance::ProvenanceSource

    function StudyPrerequisite(
        identity::ObjectIdentity,
        upstream::ProjectReference,
        automatic::Bool,
        required_contract::SemanticSchemaIdentity,
        provenance::ProvenanceSource,
    )
        upstream.kind == ReferenceStudy ||
            _semantic_fail(:invalid_study_prerequisite, "study prerequisite requires a study reference")
        return new(identity, upstream, automatic, required_contract, provenance)
    end
end

Base.:(==)(left::StudyPrerequisite, right::StudyPrerequisite) =
    left.identity == right.identity && left.upstream == right.upstream &&
    left.automatic == right.automatic && left.required_contract == right.required_contract &&
    left.provenance == right.provenance

"""One inert study request pinned to a project revision and optional resolved scenario."""
struct StudyRequest
    identity::ObjectIdentity
    schema::SemanticSchemaIdentity
    project_revision::ContentDigest
    scenario::Union{Nothing,ProjectReference}
    representation::ModelRepresentation
    fidelity::ModelFidelity
    method::StudyMethodDeclaration
    settings::CanonicalList{CanonicalField}
    initialization::CanonicalList{CanonicalField}
    events::CanonicalList{ProjectReference}
    outputs::CanonicalList{StudyOutputRequest}
    prerequisites::CanonicalList{StudyPrerequisite}
    validity::StudyValidityPolicy
    provenance::ProvenanceSource

    function StudyRequest(
        identity::ObjectIdentity,
        schema::SemanticSchemaIdentity,
        project_revision::ContentDigest,
        scenario::Union{Nothing,ProjectReference},
        representation::ModelRepresentation,
        fidelity::ModelFidelity,
        method::StudyMethodDeclaration,
        settings::AbstractVector{CanonicalField},
        initialization::AbstractVector{CanonicalField},
        events::AbstractVector{ProjectReference},
        outputs::AbstractVector{StudyOutputRequest},
        prerequisites::AbstractVector{StudyPrerequisite},
        validity::StudyValidityPolicy,
        provenance::ProvenanceSource,
    )
        !isnothing(scenario) && scenario.kind != ReferenceScenario &&
            _semantic_fail(:invalid_study_scenario, "study scenario requires a scenario reference")
        setting_copy = sort!(collect(settings); by = item -> item.name)
        initialization_copy = sort!(collect(initialization); by = item -> item.name)
        setting_names = getfield.(setting_copy, :name)
        initialization_names = getfield.(initialization_copy, :name)
        length(setting_names) == length(unique(setting_names)) ||
            _semantic_fail(:duplicate_study_setting, "study request repeats a setting")
        length(initialization_names) == length(unique(initialization_names)) ||
            _semantic_fail(:duplicate_study_initialization, "study request repeats an initialization field")
        event_copy = sort!(collect(events); by = _reference_signature)
        all(reference -> reference.kind == ReferenceEvent, event_copy) ||
            _semantic_fail(:invalid_study_event, "study event list requires event references")
        length(event_copy) == length(unique(_reference_signature(reference) for reference in event_copy)) ||
            _semantic_fail(:duplicate_study_event, "study request repeats an event")
        output_copy = sort!(collect(outputs); by = item -> item.identity.id.value)
        output_ids = getfield.(getfield.(output_copy, :identity), :id)
        length(output_ids) == length(unique(output_ids)) ||
            _semantic_fail(:duplicate_study_output, "study request repeats an output identity")
        prerequisite_copy = sort!(collect(prerequisites); by = item -> item.identity.id.value)
        prerequisite_ids = getfield.(getfield.(prerequisite_copy, :identity), :id)
        length(prerequisite_ids) == length(unique(prerequisite_ids)) ||
            _semantic_fail(:duplicate_study_prerequisite, "study request repeats a prerequisite identity")
        return new(
            identity,
            schema,
            project_revision,
            scenario,
            representation,
            fidelity,
            method,
            CanonicalList{CanonicalField}(setting_copy),
            CanonicalList{CanonicalField}(initialization_copy),
            CanonicalList{ProjectReference}(event_copy),
            CanonicalList{StudyOutputRequest}(output_copy),
            CanonicalList{StudyPrerequisite}(prerequisite_copy),
            validity,
            provenance,
        )
    end
end

Base.:(==)(left::StudyRequest, right::StudyRequest) =
    left.identity == right.identity && left.schema == right.schema &&
    left.project_revision == right.project_revision && left.scenario == right.scenario &&
    left.representation == right.representation && left.fidelity == right.fidelity &&
    left.method == right.method && left.settings == right.settings &&
    left.initialization == right.initialization && left.events == right.events &&
    left.outputs == right.outputs && left.prerequisites == right.prerequisites &&
    left.validity == right.validity && left.provenance == right.provenance

"""One versioned result shape; values remain in typed result artifacts owned by executors."""
struct ResultContract
    identity::SemanticSchemaIdentity
    fields::CanonicalList{SchemaField}
    provenance::ProvenanceSource

    function ResultContract(
        identity::SemanticSchemaIdentity,
        fields::AbstractVector{SchemaField},
        provenance::ProvenanceSource,
    )
        copied = sort!(collect(fields); by = item -> item.name)
        isempty(copied) &&
            _semantic_fail(:empty_result_contract, "result contract requires at least one typed field")
        names = getfield.(copied, :name)
        length(names) == length(unique(names)) ||
            _semantic_fail(:duplicate_result_field, "result contract repeats a field")
        return new(identity, CanonicalList{SchemaField}(copied), provenance)
    end
end

Base.:(==)(left::ResultContract, right::ResultContract) =
    left.identity == right.identity && left.fields == right.fields &&
    left.provenance == right.provenance

"""One accepted immutable result identity with exact producer and dependency hashes."""
struct ResultDeclaration
    identity::ObjectIdentity
    contract::SemanticSchemaIdentity
    producer::ProjectReference
    project_revision::ContentDigest
    scenario_hash::Union{Nothing,ContentDigest}
    study_request_hash::ContentDigest
    upstream_hashes::CanonicalList{ContentDigest}
    artifact::Union{Nothing,ArtifactIdentity}
    provenance::ProvenanceSource

    function ResultDeclaration(
        identity::ObjectIdentity,
        contract::SemanticSchemaIdentity,
        producer::ProjectReference,
        project_revision::ContentDigest,
        scenario_hash::Union{Nothing,ContentDigest},
        study_request_hash::ContentDigest,
        upstream_hashes::AbstractVector{ContentDigest},
        provenance::ProvenanceSource;
        artifact::Union{Nothing,ArtifactIdentity} = nothing,
    )
        producer.kind == ReferenceStudy ||
            _semantic_fail(:invalid_result_producer, "result producer requires a study reference")
        upstream_copy = sort!(collect(upstream_hashes); by = item -> item.sha256)
        length(upstream_copy) == length(unique(upstream_copy)) ||
            _semantic_fail(:duplicate_result_upstream_hash, "result repeats an upstream content hash")
        return new(
            identity,
            contract,
            producer,
            project_revision,
            scenario_hash,
            study_request_hash,
            CanonicalList{ContentDigest}(upstream_copy),
            artifact,
            provenance,
        )
    end
end

Base.:(==)(left::ResultDeclaration, right::ResultDeclaration) =
    left.identity == right.identity && left.contract == right.contract &&
    left.producer == right.producer && left.project_revision == right.project_revision &&
    left.scenario_hash == right.scenario_hash &&
    left.study_request_hash == right.study_request_hash &&
    left.upstream_hashes == right.upstream_hashes && left.artifact == right.artifact &&
    left.provenance == right.provenance

study_request_hash(study::StudyRequest) =
    ContentDigest(bytes2hex(SHA.sha256("aimora-study-request-v1\n" * _scenario_value_signature(study))))

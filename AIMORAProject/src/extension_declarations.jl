const _EXTENSION_STATE_FAMILIES = (
    :continuous,
    :algebraic,
    :discrete,
    :delayed,
    :scheduler,
    :random,
    :history,
    :output,
    :checkpoint,
)

@enum ExtensionService::UInt8 begin
    ExtensionInitializationService = 0x01
    ExtensionNonlinearCurrentService = 0x02
    ExtensionJacobianService = 0x03
    ExtensionCompanionStampService = 0x04
    ExtensionStateAcceptanceService = 0x05
    ExtensionEventService = 0x06
    ExtensionSampledTaskService = 0x07
    ExtensionSourceService = 0x08
    ExtensionOutputService = 0x09
    ExtensionCheckpointService = 0x0a
    ExtensionReusableDefinitionService = 0x0b
end

"""One explicit state-family disposition in an inert extension declaration."""
struct ExtensionStateDeclaration
    family::Symbol
    names::CanonicalList{ProjectId}
    not_applicable_reason::Union{Nothing,ProjectId}

    function ExtensionStateDeclaration(
        family::Symbol,
        names::AbstractVector{ProjectId} = ProjectId[];
        not_applicable_reason::Union{Nothing,ProjectId} = nothing,
    )
        family in _EXTENSION_STATE_FAMILIES || _semantic_fail(
            :unknown_extension_state_family,
            "extension state family is not part of the public contract",
        )
        copied = sort!(collect(names); by = item -> item.value)
        length(copied) == length(unique(copied)) || _semantic_fail(
            :duplicate_extension_state,
            "extension state family repeats a state identity",
        )
        if isempty(copied)
            isnothing(not_applicable_reason) && _semantic_fail(
                :missing_extension_state_disposition,
                "empty extension state family requires a not-applicable reason",
            )
        elseif !isnothing(not_applicable_reason)
            _semantic_fail(
                :conflicting_extension_state_disposition,
                "extension state family cannot own state and be not applicable",
            )
        end
        return new(family, CanonicalList{ProjectId}(copied), not_applicable_reason)
    end
end

Base.:(==)(left::ExtensionStateDeclaration, right::ExtensionStateDeclaration) =
    left.family == right.family && left.names == right.names &&
    left.not_applicable_reason == right.not_applicable_reason

function _validate_extension_parameters(parameters::Vector{AssetProperty})
    paths = getfield.(parameters, :path)
    length(paths) == length(unique(paths)) || _semantic_fail(
        :duplicate_extension_parameter,
        "extension declaration repeats a parameter path",
    )
    for parameter in parameters
        parameter.value isa Union{
            Bool,
            BigInt,
            ExactDecimal,
            ExactRational,
            PhysicalValue,
            ProjectReference,
        } || _semantic_fail(
            :executable_extension_parameter,
            "extension parameters permit only inert typed values and references",
        )
    end
    return parameters
end

"""An inert exact-identity declaration for one explicitly registered Julia extension.

The record contains no closure, source text, module or library path, loading
instruction, or executable artifact. A caller must separately load and
register the implementation before an executor may resolve this declaration.
"""
struct ExtensionDeclaration
    identity::ObjectIdentity
    implementation::RegisteredFunctionIdentity
    api_version::VersionNumber
    representation::ModelRepresentation
    fidelity::ModelFidelity
    terminals::CanonicalList{ProjectReference}
    parameters::CanonicalList{AssetProperty}
    state::CanonicalList{ExtensionStateDeclaration}
    services::CanonicalList{ExtensionService}
    upstream_results::CanonicalList{SemanticSchemaIdentity}
    output_contracts::CanonicalList{SemanticSchemaIdentity}
    reusable_definition::Union{Nothing,ProjectReference}
    provenance::ProvenanceSource

    function ExtensionDeclaration(
        identity::ObjectIdentity,
        implementation::RegisteredFunctionIdentity,
        api_version::VersionNumber,
        representation::ModelRepresentation,
        fidelity::ModelFidelity,
        terminals::AbstractVector{ProjectReference},
        parameters::AbstractVector{AssetProperty},
        state::AbstractVector{ExtensionStateDeclaration},
        services::AbstractVector{ExtensionService},
        provenance::ProvenanceSource;
        upstream_results::AbstractVector{SemanticSchemaIdentity} = SemanticSchemaIdentity[],
        output_contracts::AbstractVector{SemanticSchemaIdentity} = SemanticSchemaIdentity[],
        reusable_definition::Union{Nothing,ProjectReference} = nothing,
    )
        api_version.major == 1 || _semantic_fail(
            :unsupported_extension_api,
            "extension declaration requires public API major version 1",
        )
        terminal_copy = sort!(collect(terminals); by = _reference_signature)
        isempty(terminal_copy) && _semantic_fail(
            :missing_extension_terminal,
            "extension declaration requires at least one terminal",
        )
        all(reference -> reference.kind in (ReferenceNode, ReferenceControlBlock), terminal_copy) ||
            _semantic_fail(
                :invalid_extension_terminal,
                "extension terminals require node or control-block references",
            )
        length(terminal_copy) == length(unique(_reference_signature(item) for item in terminal_copy)) ||
            _semantic_fail(:duplicate_extension_terminal, "extension repeats a terminal")

        parameter_copy = sort!(collect(parameters); by = item -> string(item.path))
        _validate_extension_parameters(parameter_copy)

        state_copy = sort!(collect(state); by = item -> findfirst(==(item.family), _EXTENSION_STATE_FAMILIES))
        families = getfield.(state_copy, :family)
        Set(families) == Set(_EXTENSION_STATE_FAMILIES) || _semantic_fail(
            :incomplete_extension_state_inventory,
            "extension must explicitly dispose every state family",
        )
        length(families) == length(unique(families)) || _semantic_fail(
            :duplicate_extension_state_family,
            "extension repeats a state family",
        )

        service_copy = sort!(collect(services); by = UInt8)
        isempty(service_copy) && _semantic_fail(
            :missing_extension_service,
            "extension declaration requires at least one service",
        )
        length(service_copy) == length(unique(service_copy)) || _semantic_fail(
            :duplicate_extension_service,
            "extension declaration repeats a service",
        )
        ExtensionNonlinearCurrentService in service_copy &&
            !(ExtensionJacobianService in service_copy) && _semantic_fail(
                :missing_extension_jacobian,
                "nonlinear current service requires an analytic Jacobian service",
            )
        any(service -> service in (
            ExtensionNonlinearCurrentService,
            ExtensionCompanionStampService,
            ExtensionSampledTaskService,
            ExtensionSourceService,
        ), service_copy) || _semantic_fail(
            :missing_extension_execution_service,
            "extension declares no executable physical or control service",
        )
        ExtensionInitializationService in service_copy || _semantic_fail(
            :missing_extension_initialization,
            "extension execution requires an initialization service",
        )
        ExtensionCheckpointService in service_copy || _semantic_fail(
            :missing_extension_checkpoint,
            "extension execution requires a checkpoint service",
        )

        upstream_copy = sort!(collect(upstream_results); by = item -> (
            item.namespace.value,
            item.name.value,
            item.version,
        ))
        output_copy = sort!(collect(output_contracts); by = item -> (
            item.namespace.value,
            item.name.value,
            item.version,
        ))
        length(upstream_copy) == length(unique(upstream_copy)) || _semantic_fail(
            :duplicate_extension_upstream_result,
            "extension repeats an upstream result contract",
        )
        length(output_copy) == length(unique(output_copy)) || _semantic_fail(
            :duplicate_extension_output_contract,
            "extension repeats an output contract",
        )
        !isnothing(reusable_definition) && reusable_definition.kind != ReferenceDefinition &&
            _semantic_fail(
                :invalid_extension_reusable_definition,
                "extension reusable composition requires a definition reference",
            )
        return new(
            identity,
            implementation,
            api_version,
            representation,
            fidelity,
            CanonicalList{ProjectReference}(terminal_copy),
            CanonicalList{AssetProperty}(parameter_copy),
            CanonicalList{ExtensionStateDeclaration}(state_copy),
            CanonicalList{ExtensionService}(service_copy),
            CanonicalList{SemanticSchemaIdentity}(upstream_copy),
            CanonicalList{SemanticSchemaIdentity}(output_copy),
            reusable_definition,
            provenance,
        )
    end
end

Base.:(==)(left::ExtensionDeclaration, right::ExtensionDeclaration) =
    left.identity == right.identity && left.implementation == right.implementation &&
    left.api_version == right.api_version && left.representation == right.representation &&
    left.fidelity == right.fidelity && left.terminals == right.terminals &&
    left.parameters == right.parameters && left.state == right.state &&
    left.services == right.services && left.upstream_results == right.upstream_results &&
    left.output_contracts == right.output_contracts &&
    left.reusable_definition == right.reusable_definition &&
    left.provenance == right.provenance

"""One inert, one-step semantic-version migration identity."""
struct ExtensionMigrationDeclaration
    from::RegisteredFunctionIdentity
    to::RegisteredFunctionIdentity
    migration::RegisteredFunctionIdentity

    function ExtensionMigrationDeclaration(
        from::RegisteredFunctionIdentity,
        to::RegisteredFunctionIdentity,
        migration::RegisteredFunctionIdentity,
    )
        from.package_uuid == to.package_uuid || _semantic_fail(
            :extension_migration_package_mismatch,
            "extension migration cannot change package UUID",
        )
        from.package.namespace == to.package.namespace &&
            from.package.name == to.package.name || _semantic_fail(
                :extension_migration_type_mismatch,
                "extension migration cannot change semantic type",
            )
        from.package.version < to.package.version || _semantic_fail(
            :extension_migration_not_forward,
            "extension migration target must be newer than its source",
        )
        return new(from, to, migration)
    end
end

Base.:(==)(left::ExtensionMigrationDeclaration, right::ExtensionMigrationDeclaration) =
    left.from == right.from && left.to == right.to && left.migration == right.migration

extension_declaration_hash(declaration::ExtensionDeclaration) = ContentDigest(
    bytes2hex(SHA.sha256(
        "aimora-extension-declaration-v1\n" * _scenario_value_signature(declaration),
    )),
)

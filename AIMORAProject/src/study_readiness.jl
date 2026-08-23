@enum StudyReadinessState::UInt8 begin
    StudyReady = 0x01
    StudyReadyWithWarnings = 0x02
    StudyBlocked = 0x03
end

@enum ReadinessSeverity::UInt8 begin
    ReadinessInformation = 0x01
    ReadinessWarning = 0x02
    ReadinessBlocker = 0x03
end

@enum StudyReadinessCode::UInt8 begin
    MissingRequiredSetting = 0x01
    MissingRequiredInitialization = 0x02
    MissingOptionalSetting = 0x03
    MissingOptionalInitialization = 0x04
    MissingExactRealization = 0x05
    RealizationNotExecutable = 0x06
    RealizationNotQualified = 0x07
    MissingPrerequisiteResult = 0x08
    AutomaticPrerequisitePending = 0x09
    StalePrerequisiteResult = 0x0a
    UnsupportedStudyRepresentation = 0x0b
    UnsupportedStudyFidelity = 0x0c
    MissingStudySchema = 0x0d
end

"""One deterministic owner/path reason explaining readiness without executing a study."""
struct StudyReadinessReason
    code::StudyReadinessCode
    severity::ReadinessSeverity
    owner::ProjectId
    path::FieldPath
    message::String
end

Base.:(==)(left::StudyReadinessReason, right::StudyReadinessReason) =
    left.code == right.code && left.severity == right.severity &&
    left.owner == right.owner && left.path == right.path && left.message == right.message

struct StudyReadinessReport
    study::ProjectId
    state::StudyReadinessState
    reasons::CanonicalList{StudyReadinessReason}

    function StudyReadinessReport(
        study::ProjectId,
        state::StudyReadinessState,
        reasons::AbstractVector{StudyReadinessReason},
    )
        copied = sort!(collect(reasons); by = item -> (
            UInt8(item.severity),
            UInt8(item.code),
            item.owner.value,
            string(item.path),
        ))
        length(copied) == length(unique((item.code, item.owner, item.path) for item in copied)) ||
            _semantic_fail(:duplicate_readiness_reason, "study readiness repeats one owner/path reason")
        expected = any(item -> item.severity == ReadinessBlocker, copied) ? StudyBlocked :
            any(item -> item.severity == ReadinessWarning, copied) ? StudyReadyWithWarnings : StudyReady
        state == expected ||
            _semantic_fail(:readiness_state_mismatch, "study readiness state differs from its reasons")
        return new(study, state, CanonicalList{StudyReadinessReason}(copied))
    end
end

Base.:(==)(left::StudyReadinessReport, right::StudyReadinessReport) =
    left.study == right.study && left.state == right.state && left.reasons == right.reasons

function _readiness_reason(
    code::StudyReadinessCode,
    severity::ReadinessSeverity,
    owner::ProjectId,
    path::String,
    message::String,
)
    return StudyReadinessReason(code, severity, owner, FieldPath(path), message)
end

function _field_readiness_reasons(
    study::StudyRequest,
    specifications::CanonicalList{SchemaField},
    supplied::CanonicalList{CanonicalField},
    role::String,
)
    reasons = StudyReadinessReason[]
    supplied_names = Set(item.name for item in supplied)
    for field in specifications
        field.name in supplied_names && continue
        if field.required
            code = role == "settings" ? MissingRequiredSetting : MissingRequiredInitialization
            push!(reasons, _readiness_reason(
                code,
                ReadinessBlocker,
                study.identity.id,
                role * "." * field.name,
                "required study " * role * " field is absent",
            ))
        elseif study.validity.missing_optional_data == StudyOptionalDataWarning
            code = role == "settings" ? MissingOptionalSetting : MissingOptionalInitialization
            push!(reasons, _readiness_reason(
                code,
                ReadinessWarning,
                study.identity.id,
                role * "." * field.name,
                "optional study " * role * " field is absent",
            ))
        end
    end
    return reasons
end

function _study_asset_owners(study::StudyRequest)
    owners = Set{ProjectId}()
    for output in study.outputs
        output.target.kind == ReferenceAsset && output.target.target isa LocalReferenceTarget &&
            push!(owners, output.target.target.id)
    end
    return sort!(collect(owners); by = item -> item.value)
end

function _realization_readiness_reasons(project::CanonicalProject, study::StudyRequest)
    reasons = StudyReadinessReason[]
    for owner in _study_asset_owners(study)
        index = findfirst(item -> item.identity.id == owner, project.asset_library.assets)
        isnothing(index) && continue
        asset = project.asset_library.assets[index]
        realization_index = findfirst(item ->
            item.representation == study.representation && item.fidelity == study.fidelity,
            asset.realizations,
        )
        if isnothing(realization_index)
            push!(reasons, _readiness_reason(
                MissingExactRealization,
                ReadinessBlocker,
                owner,
                "realizations",
                "asset has no exact representation and fidelity realization",
            ))
            continue
        end
        realization = asset.realizations[realization_index]
        realization.availability == ModelExecutable || push!(reasons, _readiness_reason(
            RealizationNotExecutable,
            ReadinessBlocker,
            owner,
            "realizations." * realization.id.value,
            "selected realization is not executable",
        ))
        realization.qualification in (ModelQualified, ModelProduction) || push!(reasons, _readiness_reason(
            RealizationNotQualified,
            ReadinessWarning,
            owner,
            "realizations." * realization.id.value,
            "selected realization is not qualified or production evidence",
        ))
    end
    return reasons
end

function _current_prerequisite_result(
    project::CanonicalProject,
    prerequisite::StudyPrerequisite,
)
    upstream = study_request(project.orchestration, prerequisite.upstream.target.id)
    matches = ResultDeclaration[
        result for result in project.orchestration.results
        if result.producer.target isa LocalReferenceTarget &&
            result.producer.target.id == upstream.identity.id &&
            result.contract == prerequisite.required_contract
    ]
    isempty(matches) && return nothing, false
    current = findfirst(result ->
        result.project_revision == upstream.project_revision &&
        result.study_request_hash == study_request_hash(upstream) &&
        result.scenario_hash == _expected_study_scenario_hash(project, upstream),
        matches,
    )
    return isnothing(current) ? nothing : matches[current], true
end

function _prerequisite_readiness_reasons(project::CanonicalProject, study::StudyRequest)
    reasons = StudyReadinessReason[]
    for prerequisite in study.prerequisites
        result, current = _current_prerequisite_result(project, prerequisite)
        current && continue
        upstream = prerequisite.upstream.target.id
        any_result = any(candidate ->
            candidate.producer.target isa LocalReferenceTarget &&
            candidate.producer.target.id == upstream &&
            candidate.contract == prerequisite.required_contract,
            project.orchestration.results,
        )
        if any_result
            push!(reasons, _readiness_reason(
                StalePrerequisiteResult,
                ReadinessBlocker,
                upstream,
                "results",
                "accepted prerequisite result is stale",
            ))
        elseif prerequisite.automatic
            push!(reasons, _readiness_reason(
                AutomaticPrerequisitePending,
                ReadinessWarning,
                upstream,
                "results",
                "automatic prerequisite is declared but not yet computed",
            ))
        else
            push!(reasons, _readiness_reason(
                MissingPrerequisiteResult,
                ReadinessBlocker,
                upstream,
                "results",
                "required prerequisite result is absent",
            ))
        end
    end
    return reasons
end

"""Return exact deterministic readiness reasons without running a solver or workflow."""
function study_readiness(project::CanonicalProject, id::ProjectId)
    study = study_request(project.orchestration, id)
    schema_index = findfirst(item -> item.identity == study.schema, project.orchestration.study_schemas)
    if isnothing(schema_index)
        reason = _readiness_reason(
            MissingStudySchema,
            ReadinessBlocker,
            study.identity.id,
            "schema",
            "study request schema is not registered",
        )
        return StudyReadinessReport(id, StudyBlocked, [reason])
    end
    schema = project.orchestration.study_schemas[schema_index]
    reasons = StudyReadinessReason[]
    study.representation in schema.representations || push!(reasons, _readiness_reason(
        UnsupportedStudyRepresentation,
        ReadinessBlocker,
        study.identity.id,
        "representation",
        "study representation is outside its owner schema",
    ))
    study.fidelity in schema.fidelities || push!(reasons, _readiness_reason(
        UnsupportedStudyFidelity,
        ReadinessBlocker,
        study.identity.id,
        "fidelity",
        "study fidelity is outside its owner schema",
    ))
    append!(reasons, _field_readiness_reasons(study, schema.settings, study.settings, "settings"))
    append!(reasons, _field_readiness_reasons(study, schema.initialization, study.initialization, "initialization"))
    append!(reasons, _realization_readiness_reasons(project, study))
    append!(reasons, _prerequisite_readiness_reasons(project, study))
    state = any(item -> item.severity == ReadinessBlocker, reasons) ? StudyBlocked :
        any(item -> item.severity == ReadinessWarning, reasons) ? StudyReadyWithWarnings : StudyReady
    return StudyReadinessReport(id, state, reasons)
end

missing_requirements(report::StudyReadinessReport) = CanonicalList{StudyReadinessReason}(
    StudyReadinessReason[item for item in report.reasons if item.severity == ReadinessBlocker],
)

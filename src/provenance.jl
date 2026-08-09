"""A nonempty licence identity, preferably an SPDX identifier, with optional public URI."""
struct LicenceIdentity
    id::String
    name::String
    uri::Union{Nothing,GlobalId}

    function LicenceIdentity(
        id::AbstractString,
        name::AbstractString;
        uri::Union{Nothing,GlobalId} = nothing,
    )
        normalized_id = String(id)
        occursin(r"^[A-Za-z0-9][A-Za-z0-9.+-]*$", normalized_id) ||
            _semantic_fail(:invalid_licence_id, "licence ID is not portable")
        normalized_name = String(name)
        isempty(strip(normalized_name)) && _semantic_fail(:invalid_licence_name, "licence name must not be empty")
        occursin('\0', normalized_name) && _semantic_fail(:invalid_licence_name, "licence name contains NUL")
        return new(normalized_id, normalized_name, uri)
    end
end

Base.:(==)(left::LicenceIdentity, right::LicenceIdentity) =
    left.id == right.id && left.name == right.name && left.uri == right.uri

"""Field-level source provenance with an optional exact source hash and version."""
struct ProvenanceSource
    id::ProjectId
    citation::String
    source_uri::Union{Nothing,GlobalId}
    source_sha256::Union{Nothing,String}
    source_version::Union{Nothing,String}
    licence::LicenceIdentity

    function ProvenanceSource(
        id::ProjectId,
        citation::AbstractString,
        licence::LicenceIdentity;
        source_uri::Union{Nothing,GlobalId} = nothing,
        source_sha256::Union{Nothing,AbstractString} = nothing,
        source_version::Union{Nothing,AbstractString} = nothing,
    )
        normalized_citation = String(citation)
        isempty(strip(normalized_citation)) && _semantic_fail(:missing_provenance_citation, "provenance citation must not be empty")
        occursin('\0', normalized_citation) && _semantic_fail(:invalid_provenance_citation, "provenance citation contains NUL")
        digest = isnothing(source_sha256) ? nothing : String(source_sha256)
        !isnothing(digest) && !occursin(r"^[0-9a-f]{64}$", digest) &&
            _semantic_fail(:invalid_source_sha256, "provenance source SHA-256 must be lowercase hexadecimal")
        version = isnothing(source_version) ? nothing : String(source_version)
        !isnothing(version) && isempty(strip(version)) &&
            _semantic_fail(:invalid_source_version, "provenance source version must not be empty")
        return new(id, normalized_citation, source_uri, digest, version, licence)
    end
end

Base.:(==)(left::ProvenanceSource, right::ProvenanceSource) =
    left.id == right.id &&
    left.citation == right.citation &&
    left.source_uri == right.source_uri &&
    left.source_sha256 == right.source_sha256 &&
    left.source_version == right.source_version &&
    left.licence == right.licence

function _portable_artifact_path(path::String)
    isempty(path) && return false
    startswith(path, '/') && return false
    occursin('\\', path) && return false
    occursin(r"^[A-Za-z]:", path) && return false
    segments = split(path, '/')
    return all(segment -> !isempty(segment) && segment ∉ (".", ".."), segments)
end

"""A checksummed portable artifact identity without any file-loading behavior."""
struct ArtifactIdentity
    id::ProjectId
    path::String
    sha256::String
    media_type::String
    schema::Union{Nothing,SemanticTypeId}
    byte_count::Union{Nothing,Int}
    provenance::ProvenanceSource

    function ArtifactIdentity(
        id::ProjectId,
        path::AbstractString,
        sha256::AbstractString,
        media_type::AbstractString,
        provenance::ProvenanceSource;
        schema::Union{Nothing,SemanticTypeId} = nothing,
        byte_count::Union{Nothing,Integer} = nothing,
    )
        normalized_path = String(path)
        _portable_artifact_path(normalized_path) ||
            _semantic_fail(:invalid_artifact_path, "artifact path must be portable and project-relative")
        digest = String(sha256)
        occursin(r"^[0-9a-f]{64}$", digest) ||
            _semantic_fail(:invalid_artifact_sha256, "artifact SHA-256 must be lowercase hexadecimal")
        media = String(media_type)
        occursin(r"^[A-Za-z0-9][A-Za-z0-9!#$&^_.+-]*/[A-Za-z0-9][A-Za-z0-9!#$&^_.+-]*$", media) ||
            _semantic_fail(:invalid_artifact_media_type, "artifact media type is malformed")
        count = isnothing(byte_count) ? nothing : try
            Int(byte_count)
        catch
            _semantic_fail(:invalid_artifact_size, "artifact byte count exceeds Int")
        end
        !isnothing(count) && count < 0 && _semantic_fail(:invalid_artifact_size, "artifact byte count must be nonnegative")
        return new(id, normalized_path, digest, media, schema, count, provenance)
    end
end

Base.:(==)(left::ArtifactIdentity, right::ArtifactIdentity) =
    left.id == right.id &&
    left.path == right.path &&
    left.sha256 == right.sha256 &&
    left.media_type == right.media_type &&
    left.schema == right.schema &&
    left.byte_count == right.byte_count &&
    left.provenance == right.provenance

@enum UncertaintyKind::UInt8 begin
    UncertaintyNormal = 0x01
    UncertaintyUniform = 0x02
    UncertaintyInterval = 0x03
end

"""A typed quantity uncertainty contract with exact parameters and confidence."""
struct QuantityUncertainty
    kind::UncertaintyKind
    standard_deviation::Union{Nothing,ScalarQuantity}
    lower::Union{Nothing,ScalarQuantity}
    upper::Union{Nothing,ScalarQuantity}
    confidence::ExactDecimal

    function QuantityUncertainty(
        kind::UncertaintyKind,
        confidence::ExactDecimal;
        standard_deviation::Union{Nothing,ScalarQuantity} = nothing,
        lower::Union{Nothing,ScalarQuantity} = nothing,
        upper::Union{Nothing,ScalarQuantity} = nothing,
    )
        confidence_value = exact_rational(confidence)
        ExactRational(0) < confidence_value <= ExactRational(1) ||
            _semantic_fail(:invalid_uncertainty_confidence, "uncertainty confidence must be in (0, 1]")
        if kind == UncertaintyNormal
            isnothing(standard_deviation) && _semantic_fail(:missing_uncertainty_parameter, "normal uncertainty requires standard deviation")
            (!isnothing(lower) || !isnothing(upper)) &&
                _semantic_fail(:conflicting_uncertainty_parameter, "normal uncertainty does not accept interval bounds")
            ExactRational(0) < exact_rational(standard_deviation.value) ||
                _semantic_fail(:invalid_uncertainty_parameter, "standard deviation must be positive")
        else
            !isnothing(standard_deviation) &&
                _semantic_fail(:conflicting_uncertainty_parameter, "interval uncertainty does not accept standard deviation")
            (isnothing(lower) || isnothing(upper)) &&
                _semantic_fail(:missing_uncertainty_parameter, "uniform or interval uncertainty requires lower and upper bounds")
            lower.unit == upper.unit && lower.orientation == upper.orientation && lower.base == upper.base ||
                _semantic_fail(:uncertainty_quantity_mismatch, "uncertainty bounds use different quantity metadata")
            exact_rational(lower.value) < exact_rational(upper.value) ||
                _semantic_fail(:invalid_uncertainty_parameter, "uncertainty lower bound must be below upper bound")
        end
        return new(kind, standard_deviation, lower, upper, confidence)
    end
end

Base.:(==)(left::QuantityUncertainty, right::QuantityUncertainty) =
    left.kind == right.kind &&
    left.standard_deviation == right.standard_deviation &&
    left.lower == right.lower &&
    left.upper == right.upper &&
    left.confidence == right.confidence

"""A physical value whose uncertainty and provenance are explicit canonical data."""
struct PhysicalValue{Q<:Union{ScalarQuantity,ComplexQuantity}}
    quantity::Q
    uncertainty::Union{Nothing,QuantityUncertainty}
    provenance::ProvenanceSource
end

PhysicalValue(
    quantity::Q,
    provenance::ProvenanceSource;
    uncertainty::Union{Nothing,QuantityUncertainty} = nothing,
) where {Q<:Union{ScalarQuantity,ComplexQuantity}} = PhysicalValue{Q}(quantity, uncertainty, provenance)

Base.:(==)(left::PhysicalValue, right::PhysicalValue) =
    left.quantity == right.quantity &&
    left.uncertainty == right.uncertainty &&
    left.provenance == right.provenance

function validate_quantity(registry::UnitRegistry, value::PhysicalValue)
    validate_quantity(registry, value.quantity)
    uncertainty = value.uncertainty
    isnothing(uncertainty) && return true
    quantity = value.quantity
    quantity_unit = lookup_unit(registry, quantity.unit)
    if !isnothing(uncertainty.standard_deviation)
        parameter = uncertainty.standard_deviation
        validate_quantity(registry, parameter)
        parameter_unit = lookup_unit(registry, parameter.unit)
        parameter_unit.dimension == quantity_unit.dimension && parameter.base == quantity.base ||
            _semantic_fail(:uncertainty_quantity_mismatch, "uncertainty standard deviation has a different dimension or base")
        if quantity_unit.affine_kind == UnitAbsoluteTemperature
            parameter_unit.affine_kind == UnitTemperatureDifference &&
                parameter.orientation == OrientationTemperatureDifference ||
                _semantic_fail(:uncertainty_quantity_mismatch, "absolute-temperature uncertainty requires a temperature-difference standard deviation")
        else
            parameter_unit.affine_kind == quantity_unit.affine_kind &&
                parameter.orientation == quantity.orientation ||
                _semantic_fail(:uncertainty_quantity_mismatch, "uncertainty standard deviation has incompatible unit or orientation metadata")
        end
    end
    for parameter in (uncertainty.lower, uncertainty.upper)
        isnothing(parameter) && continue
        validate_quantity(registry, parameter)
        parameter_unit = lookup_unit(registry, parameter.unit)
        parameter_unit.dimension == quantity_unit.dimension &&
            parameter_unit.affine_kind == quantity_unit.affine_kind &&
            parameter.base == quantity.base &&
            parameter.orientation == quantity.orientation ||
            _semantic_fail(:uncertainty_quantity_mismatch, "uncertainty bound has incompatible quantity metadata")
    end
    return true
end

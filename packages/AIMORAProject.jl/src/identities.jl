"""A typed semantic validation failure with a stable machine-readable code."""
struct SemanticValidationError <: Exception
    code::Symbol
    message::String

    function SemanticValidationError(code::Symbol, message::AbstractString)
        occursin(r"^[a-z][a-z0-9_]*$", String(code)) ||
            throw(ArgumentError("semantic validation code is not portable"))
        normalized = String(message)
        isempty(normalized) && throw(ArgumentError("semantic validation message must not be empty"))
        return new(code, normalized)
    end
end

Base.showerror(io::IO, error::SemanticValidationError) =
    print(io, String(error.code), ": ", error.message)

_semantic_fail(code::Symbol, message::AbstractString) =
    throw(SemanticValidationError(code, message))

"""An insertion-ordered immutable collection used by canonical semantic records."""
struct CanonicalList{T,D<:Tuple}
    data::D

    function CanonicalList{T}(items::AbstractVector{<:T}) where {T}
        copied = Tuple(T[item for item in items])
        return new{T,typeof(copied)}(copied)
    end
end

CanonicalList(items::AbstractVector{T}) where {T} = CanonicalList{T}(items)
CanonicalList{T}() where {T} = CanonicalList{T}(T[])

Base.eltype(::Type{<:CanonicalList{T}}) where {T} = T
Base.length(items::CanonicalList) = length(items.data)
Base.isempty(items::CanonicalList) = isempty(items.data)
Base.getindex(items::CanonicalList, index::Int) = items.data[index]
Base.firstindex(::CanonicalList) = 1
Base.lastindex(items::CanonicalList) = length(items)
Base.keys(items::CanonicalList) = Base.OneTo(length(items))
Base.eachindex(items::CanonicalList) = Base.OneTo(length(items))
Base.iterate(items::CanonicalList, state...) = iterate(items.data, state...)
Base.collect(items::CanonicalList{T}) where {T} = T[item for item in items]
Base.:(==)(left::CanonicalList, right::CanonicalList) = left.data == right.data

const _PROJECT_ID_SEGMENT = r"^[A-Za-z][A-Za-z0-9_-]*$"
const _NAMESPACE_ID = r"^[a-z][a-z0-9_-]*(?:\.[a-z][a-z0-9_-]*)*$"

"""A stable human-readable project-local identity made from portable dotted segments."""
struct ProjectId
    value::String

    function ProjectId(value::AbstractString)
        normalized = String(value)
        segments = split(normalized, '.')
        isempty(normalized) || all(segment -> occursin(_PROJECT_ID_SEGMENT, segment), segments) ||
            _semantic_fail(:invalid_project_id, "project ID must contain portable dotted segments")
        isempty(normalized) && _semantic_fail(:invalid_project_id, "project ID must not be empty")
        return new(normalized)
    end
end

Base.string(id::ProjectId) = id.value
Base.show(io::IO, id::ProjectId) = print(io, id.value)
Base.:(==)(left::ProjectId, right::ProjectId) = left.value == right.value
Base.hash(id::ProjectId, seed::UInt) = hash(id.value, seed)

"""A lowercase organization or extension namespace."""
struct NamespaceId
    value::String

    function NamespaceId(value::AbstractString)
        normalized = String(value)
        occursin(_NAMESPACE_ID, normalized) ||
            _semantic_fail(:invalid_namespace_id, "namespace must use lowercase dotted portable segments")
        return new(normalized)
    end
end

Base.string(id::NamespaceId) = id.value
Base.show(io::IO, id::NamespaceId) = print(io, id.value)
Base.:(==)(left::NamespaceId, right::NamespaceId) = left.value == right.value
Base.hash(id::NamespaceId, seed::UInt) = hash(id.value, seed)

"""An optional globally unique absolute URI identity."""
struct GlobalId
    uri::String

    function GlobalId(uri::AbstractString)
        normalized = String(uri)
        isvalid(normalized) || _semantic_fail(:invalid_global_id, "global ID is not valid Unicode")
        occursin(r"^[A-Za-z][A-Za-z0-9+.-]*:[^\s\x00-\x1f\x7f]+$", normalized) ||
            _semantic_fail(:invalid_global_id, "global ID must be an absolute URI without controls")
        return new(normalized)
    end
end

GlobalId(uuid::UUID) = GlobalId(string("urn:uuid:", uuid))
Base.string(id::GlobalId) = id.uri
Base.:(==)(left::GlobalId, right::GlobalId) = left.uri == right.uri
Base.hash(id::GlobalId, seed::UInt) = hash(id.uri, seed)

"""One immutable local object identity and its optional global identity."""
struct ObjectIdentity
    id::ProjectId
    uid::Union{Nothing,GlobalId}
end

ObjectIdentity(id::ProjectId; uid::Union{Nothing,GlobalId} = nothing) = ObjectIdentity(id, uid)
Base.:(==)(left::ObjectIdentity, right::ObjectIdentity) = left.id == right.id && left.uid == right.uid

"""A display name paired with immutable object identity."""
struct IdentifiedName
    identity::ObjectIdentity
    name::String

    function IdentifiedName(identity::ObjectIdentity, name::AbstractString)
        normalized = String(name)
        isempty(strip(normalized)) && _semantic_fail(:invalid_display_name, "display name must not be empty")
        occursin('\0', normalized) && _semantic_fail(:invalid_display_name, "display name contains NUL")
        return new(identity, normalized)
    end
end

"""Return a renamed immutable value without changing either local or global identity."""
rename(value::IdentifiedName, name::AbstractString) = IdentifiedName(value.identity, name)
Base.:(==)(left::IdentifiedName, right::IdentifiedName) = left.identity == right.identity && left.name == right.name

"""A versioned semantic type name owned by a namespace."""
struct SemanticTypeId
    namespace::NamespaceId
    name::ProjectId
    version::VersionNumber

    function SemanticTypeId(namespace::NamespaceId, name::ProjectId, version::VersionNumber)
        version.major > 0 || _semantic_fail(:invalid_type_version, "semantic type major version must be positive")
        return new(namespace, name, version)
    end
end

Base.:(==)(left::SemanticTypeId, right::SemanticTypeId) =
    left.namespace == right.namespace && left.name == right.name && left.version == right.version
Base.hash(id::SemanticTypeId, seed::UInt) = hash((id.namespace, id.name, id.version), seed)

@enum ReferenceKind::UInt8 begin
    ReferenceAsset = 0x01
    ReferenceNode = 0x02
    ReferenceProfile = 0x03
    ReferenceCurve = 0x04
    ReferenceEvent = 0x05
    ReferenceScenario = 0x06
    ReferenceStudy = 0x07
    ReferenceWorkflow = 0x08
    ReferenceResult = 0x09
    ReferenceCatalog = 0x0a
    ReferencePlugin = 0x0b
    ReferenceDefinition = 0x0c
    ReferenceControlBlock = 0x0d
    ReferenceView = 0x0e
end

"""One decoded RFC 6901 JSON Pointer token."""
struct ReferenceToken
    value::String

    function ReferenceToken(value::AbstractString)
        normalized = String(value)
        isvalid(normalized) || _semantic_fail(:invalid_reference_path, "reference token is not valid Unicode")
        occursin('\0', normalized) && _semantic_fail(:invalid_reference_path, "reference token contains NUL")
        return new(normalized)
    end
end

Base.:(==)(left::ReferenceToken, right::ReferenceToken) = left.value == right.value
Base.hash(token::ReferenceToken, seed::UInt) = hash(token.value, seed)

"""A typed, decoded, immutable path into a referenced semantic object."""
struct ReferencePath
    tokens::CanonicalList{ReferenceToken}
end

ReferencePath(tokens::AbstractVector{ReferenceToken} = ReferenceToken[]) =
    ReferencePath(CanonicalList{ReferenceToken}(tokens))
Base.:(==)(left::ReferencePath, right::ReferencePath) = left.tokens == right.tokens

function ReferencePath(pointer::AbstractString)
    text = String(pointer)
    isempty(text) && return ReferencePath()
    startswith(text, '/') || _semantic_fail(:invalid_reference_path, "JSON Pointer path must be empty or begin with slash")
    tokens = ReferenceToken[]
    for encoded in split(text[2:end], '/'; keepempty = true)
        output = IOBuffer()
        index = firstindex(encoded)
        while index <= lastindex(encoded)
            character = encoded[index]
            if character == '~'
                next_index = nextind(encoded, index)
                next_index <= lastindex(encoded) || _semantic_fail(:invalid_reference_path, "JSON Pointer has a trailing tilde escape")
                escaped = encoded[next_index]
                escaped in ('0', '1') || _semantic_fail(:invalid_reference_path, "JSON Pointer contains an invalid tilde escape")
                write(output, escaped == '0' ? '~' : '/')
                index = nextind(encoded, next_index)
            else
                write(output, character)
                index = nextind(encoded, index)
            end
        end
        push!(tokens, ReferenceToken(String(take!(output))))
    end
    return ReferencePath(tokens)
end

abstract type ReferenceTarget end

struct LocalReferenceTarget <: ReferenceTarget
    id::ProjectId
end

struct GlobalReferenceTarget <: ReferenceTarget
    id::GlobalId
end


Base.:(==)(left::LocalReferenceTarget, right::LocalReferenceTarget) = left.id == right.id
Base.:(==)(left::GlobalReferenceTarget, right::GlobalReferenceTarget) = left.id == right.id

const SemanticReferenceTarget = Union{LocalReferenceTarget,GlobalReferenceTarget}

"""A kind-checked stable reference with an optional typed object path."""
struct ProjectReference
    kind::ReferenceKind
    target::SemanticReferenceTarget
    path::ReferencePath
end

ProjectReference(kind::ReferenceKind, id::ProjectId; path::ReferencePath = ReferencePath()) =
    ProjectReference(kind, LocalReferenceTarget(id), path)

ProjectReference(kind::ReferenceKind, id::GlobalId; path::ReferencePath = ReferencePath()) =
    ProjectReference(kind, GlobalReferenceTarget(id), path)

Base.:(==)(left::ProjectReference, right::ProjectReference) =
    left.kind == right.kind && left.target == right.target && left.path == right.path

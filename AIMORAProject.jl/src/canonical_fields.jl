"""A lowercase SHA-256 content identity supplied by an admitted source or semantic normalizer."""
struct ContentDigest
    sha256::String

    function ContentDigest(sha256::AbstractString)
        normalized = String(sha256)
        occursin(r"^[0-9a-f]{64}$", normalized) ||
            _semantic_fail(:invalid_content_digest, "content digest must be lowercase SHA-256 hexadecimal")
        return new(normalized)
    end
end

Base.string(digest::ContentDigest) = digest.sha256
Base.:(==)(left::ContentDigest, right::ContentDigest) = left.sha256 == right.sha256
Base.hash(digest::ContentDigest, seed::UInt) = hash(digest.sha256, seed)

const CanonicalFieldData = Union{
    Bool,
    BigInt,
    ExactDecimal,
    ExactRational,
    String,
    PhysicalValue,
    ProjectReference,
    ArtifactIdentity,
}

"""One immutable schema-owned canonical field value."""
struct CanonicalField
    name::String
    value::CanonicalFieldData

    function CanonicalField(name::AbstractString, value::CanonicalFieldData)
        normalized = String(name)
        occursin(r"^[a-z][a-z0-9_]*$", normalized) ||
            _semantic_fail(:invalid_canonical_field_name, "canonical field name is not lowercase portable text")
        owned_value = value isa String ? String(value) : value
        owned_value isa String && occursin('\0', owned_value) &&
            _semantic_fail(:invalid_canonical_string, "canonical string value contains NUL")
        return new(normalized, owned_value)
    end
end

CanonicalField(name::AbstractString, value::Integer) = CanonicalField(name, BigInt(value))
CanonicalField(name::AbstractString, value::AbstractString) = CanonicalField(name, String(value))
Base.:(==)(left::CanonicalField, right::CanonicalField) = left.name == right.name && left.value == right.value

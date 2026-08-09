const _MAX_EXACT_DECIMAL_DIGITS = 4096
const _MAX_EXACT_DECIMAL_EXPONENT = 10_000

"""A normalized exact finite base-ten decimal."""
struct ExactDecimal
    coefficient::BigInt
    exponent::Int
    negative_zero::Bool

    function ExactDecimal(
        coefficient::Integer,
        exponent::Integer;
        negative_zero::Bool = false,
    )
        normalized_coefficient = BigInt(coefficient)
        normalized_exponent = try
            Int(exponent)
        catch
            _semantic_fail(:decimal_exponent_out_of_range, "exact decimal exponent exceeds Int")
        end
        abs(normalized_exponent) <= _MAX_EXACT_DECIMAL_EXPONENT ||
            _semantic_fail(:decimal_exponent_out_of_range, "exact decimal exponent exceeds the canonical engineering limit")
        ndigits(abs(normalized_coefficient)) <= _MAX_EXACT_DECIMAL_DIGITS ||
            _semantic_fail(:decimal_coefficient_too_large, "exact decimal coefficient exceeds the canonical digit limit")
        if iszero(normalized_coefficient)
            return new(BigInt(0), 0, negative_zero)
        end
        negative_zero && _semantic_fail(:invalid_negative_zero, "only zero can retain a negative sign")
        while iszero(rem(normalized_coefficient, 10))
            normalized_coefficient = div(normalized_coefficient, 10)
            normalized_exponent += 1
            normalized_exponent <= _MAX_EXACT_DECIMAL_EXPONENT ||
                _semantic_fail(:decimal_exponent_out_of_range, "normalized decimal exponent exceeds the canonical limit")
        end
        return new(normalized_coefficient, normalized_exponent, false)
    end
end

Base.:(==)(left::ExactDecimal, right::ExactDecimal) =
    left.coefficient == right.coefficient &&
    left.exponent == right.exponent &&
    left.negative_zero == right.negative_zero

function Base.string(value::ExactDecimal)
    prefix = value.negative_zero ? "-" : ""
    return string(prefix, value.coefficient, 'e', value.exponent)
end

"""Parse one finite JSON-style decimal without binary floating-point conversion."""
function parse_exact_decimal(text::AbstractString)
    source = String(text)
    ncodeunits(source) <= _MAX_EXACT_DECIMAL_DIGITS + 32 ||
        _semantic_fail(:decimal_literal_too_large, "exact decimal literal exceeds the canonical byte limit")
    matched = match(r"^(-?)(0|[1-9][0-9]*)(?:\.([0-9]+))?(?:[eE]([+-]?[0-9]+))?$", source)
    isnothing(matched) && _semantic_fail(:invalid_exact_decimal, "exact decimal literal is malformed or ambiguous")
    fraction = something(matched.captures[3], "")
    exponent_text = something(matched.captures[4], "0")
    explicit_exponent = tryparse(BigInt, exponent_text)
    isnothing(explicit_exponent) && _semantic_fail(:decimal_exponent_out_of_range, "exact decimal exponent is malformed")
    total_exponent = explicit_exponent - ncodeunits(fraction)
    typemin(Int) <= total_exponent <= typemax(Int) ||
        _semantic_fail(:decimal_exponent_out_of_range, "exact decimal exponent exceeds Int")
    coefficient = parse(BigInt, string(matched.captures[2], fraction))
    matched.captures[1] == "-" && (coefficient = -coefficient)
    return ExactDecimal(
        coefficient,
        Int(total_exponent);
        negative_zero = iszero(coefficient) && matched.captures[1] == "-",
    )
end

"""A normalized exact rational used by lossless unit and base conversion."""
struct ExactRational
    numerator::BigInt
    denominator::BigInt
    negative_zero::Bool

    function ExactRational(
        numerator::Integer,
        denominator::Integer = 1;
        negative_zero::Bool = false,
    )
        normalized_numerator = BigInt(numerator)
        normalized_denominator = BigInt(denominator)
        iszero(normalized_denominator) && _semantic_fail(:zero_exact_denominator, "exact rational denominator must not be zero")
        if normalized_denominator < 0
            normalized_numerator = -normalized_numerator
            normalized_denominator = -normalized_denominator
        end
        divisor = gcd(abs(normalized_numerator), normalized_denominator)
        normalized_numerator = div(normalized_numerator, divisor)
        normalized_denominator = div(normalized_denominator, divisor)
        if iszero(normalized_numerator)
            return new(BigInt(0), BigInt(1), negative_zero)
        end
        negative_zero && _semantic_fail(:invalid_negative_zero, "only zero can retain a negative sign")
        return new(normalized_numerator, normalized_denominator, false)
    end
end

Base.:(==)(left::ExactRational, right::ExactRational) =
    left.numerator == right.numerator &&
    left.denominator == right.denominator &&
    left.negative_zero == right.negative_zero

const ExactScalar = Union{ExactDecimal,ExactRational}

exact_rational(value::ExactRational) = value

function exact_rational(value::ExactDecimal)
    if value.exponent >= 0
        return ExactRational(
            value.coefficient * big(10)^value.exponent,
            1;
            negative_zero = value.negative_zero,
        )
    end
    return ExactRational(
        value.coefficient,
        big(10)^(-value.exponent);
        negative_zero = value.negative_zero,
    )
end

Base.:-(value::ExactRational) = ExactRational(-value.numerator, value.denominator; negative_zero = iszero(value.numerator) && !value.negative_zero)
Base.:+(left::ExactRational, right::ExactRational) = ExactRational(
    left.numerator * right.denominator + right.numerator * left.denominator,
    left.denominator * right.denominator,
)
Base.:-(left::ExactRational, right::ExactRational) = left + (-right)
Base.:*(left::ExactRational, right::ExactRational) = ExactRational(
    left.numerator * right.numerator,
    left.denominator * right.denominator;
    negative_zero = iszero(left.numerator * right.numerator) && xor(left.negative_zero, right.negative_zero),
)
Base.:/(left::ExactRational, right::ExactRational) = begin
    iszero(right.numerator) && _semantic_fail(:division_by_zero, "exact rational division by zero")
    ExactRational(
        left.numerator * right.denominator,
        left.denominator * right.numerator;
        negative_zero = iszero(left.numerator) && xor(left.negative_zero, right.numerator < 0),
    )
end
Base.isless(left::ExactRational, right::ExactRational) =
    left.numerator * right.denominator < right.numerator * left.denominator
Base.:<(left::ExactRational, right::ExactRational) = isless(left, right)
Base.:<=(left::ExactRational, right::ExactRational) =
    left.numerator * right.denominator <= right.numerator * left.denominator

"""SI base-dimension exponents ordered as length, mass, time, current, temperature, amount, luminous intensity."""
struct DimensionVector
    exponents::NTuple{7,Rational{Int16}}
end

DimensionVector(exponents::NTuple{7,<:Integer}) = DimensionVector(ntuple(index -> Int16(exponents[index]) // Int16(1), 7))

dimensionless() = DimensionVector((0, 0, 0, 0, 0, 0, 0))

function _dimension(length, mass, time, current, temperature, amount = 0, luminous = 0)
    return DimensionVector((length, mass, time, current, temperature, amount, luminous))
end

"""A controlled, registry-resolved UCUM-compatible unit identifier."""
struct UnitId
    value::String

    function UnitId(value::AbstractString)
        normalized = String(value)
        isvalid(normalized) || _semantic_fail(:invalid_unit_id, "unit ID is not valid Unicode")
        occursin(r"^(?:1|%|[A-Za-z][A-Za-z0-9%._/*^{}-]*)$", normalized) ||
            _semantic_fail(:invalid_unit_id, "unit ID is outside the controlled portable grammar")
        return new(normalized)
    end
end

Base.string(id::UnitId) = id.value
Base.:(==)(left::UnitId, right::UnitId) = left.value == right.value
Base.hash(id::UnitId, seed::UInt) = hash(id.value, seed)

@enum UnitAffineKind::UInt8 begin
    UnitLinear = 0x01
    UnitAbsoluteTemperature = 0x02
    UnitTemperatureDifference = 0x03
end

"""One exact unit definition relative to the canonical SI unit for its dimension."""
struct UnitDefinition
    id::UnitId
    dimension::DimensionVector
    scale::ExactRational
    offset::ExactRational
    affine_kind::UnitAffineKind
    per_unit::Bool

    function UnitDefinition(
        id::UnitId,
        dimension::DimensionVector,
        scale::ExactRational;
        offset::ExactRational = ExactRational(0),
        affine_kind::UnitAffineKind = UnitLinear,
        per_unit::Bool = false,
    )
        ExactRational(0) < scale || _semantic_fail(:invalid_unit_scale, "unit scale must be positive")
        affine_kind != UnitAbsoluteTemperature && offset != ExactRational(0) &&
            _semantic_fail(:invalid_unit_offset, "only absolute-temperature units may have an offset")
        per_unit && (dimension != dimensionless() || affine_kind != UnitLinear || offset != ExactRational(0)) &&
            _semantic_fail(:invalid_per_unit_definition, "per-unit definition must be linear and dimensionless")
        return new(id, dimension, scale, offset, affine_kind, per_unit)
    end
end

Base.:(==)(left::UnitDefinition, right::UnitDefinition) =
    left.id == right.id &&
    left.dimension == right.dimension &&
    left.scale == right.scale &&
    left.offset == right.offset &&
    left.affine_kind == right.affine_kind &&
    left.per_unit == right.per_unit

"""An immutable registry of exact controlled unit definitions."""
struct UnitRegistry
    units::CanonicalList{UnitDefinition}

    function UnitRegistry(units::AbstractVector{UnitDefinition} = UnitDefinition[])
        copied = sort!(collect(units); by = unit -> unit.id.value)
        ids = getfield.(getfield.(copied, :id), :value)
        length(ids) == length(unique(ids)) || _semantic_fail(:duplicate_unit_id, "unit registry repeats an ID")
        return new(CanonicalList{UnitDefinition}(copied))
    end
end

Base.:(==)(left::UnitRegistry, right::UnitRegistry) = left.units == right.units

function lookup_unit(registry::UnitRegistry, id::UnitId)
    index = findfirst(unit -> unit.id == id, registry.units)
    isnothing(index) && _semantic_fail(:unknown_unit_id, "unit $(id.value) is not registered")
    return registry.units[index]
end

function register_unit(registry::UnitRegistry, definition::UnitDefinition)
    existing = findfirst(unit -> unit.id == definition.id, registry.units)
    if !isnothing(existing)
        registry.units[existing] == definition && return registry
        _semantic_fail(:unit_definition_collision, "unit ID $(definition.id.value) already has a different definition")
    end
    return UnitRegistry(vcat(collect(registry.units), [definition]))
end

@enum BaseKind::UInt8 begin
    BaseSystem = 0x01
    BaseAsset = 0x02
    BaseVoltage = 0x03
    BaseCustom = 0x04
end

struct BaseReference
    kind::BaseKind
    reference::ProjectReference
end


Base.:(==)(left::BaseReference, right::BaseReference) =
    left.kind == right.kind && left.reference == right.reference

@enum QuantityOrientation::UInt8 begin
    OrientationScalar = 0x01
    OrientationPhaseToGroundRms = 0x02
    OrientationPhaseToPhaseRms = 0x03
    OrientationInstantaneous = 0x04
    OrientationPeak = 0x05
    OrientationPositiveSequence = 0x06
    OrientationIntoAsset = 0x07
    OrientationOutOfAsset = 0x08
    OrientationAbsoluteTemperature = 0x09
    OrientationTemperatureDifference = 0x0a
end

"""An exact scalar engineering quantity with explicit unit, base, and orientation."""
struct ScalarQuantity
    value::ExactScalar
    unit::UnitId
    base::Union{Nothing,BaseReference}
    orientation::QuantityOrientation
end

ScalarQuantity(
    value::ExactScalar,
    unit::UnitId,
    orientation::QuantityOrientation;
    base::Union{Nothing,BaseReference} = nothing,
) = ScalarQuantity(value, unit, base, orientation)

Base.:(==)(left::ScalarQuantity, right::ScalarQuantity) =
    left.value == right.value &&
    left.unit == right.unit &&
    left.base == right.base &&
    left.orientation == right.orientation

"""An exact complex engineering quantity with one explicit unit, base, and orientation."""
struct ComplexQuantity
    real::ExactScalar
    imag::ExactScalar
    unit::UnitId
    base::Union{Nothing,BaseReference}
    orientation::QuantityOrientation
end

ComplexQuantity(
    real::ExactScalar,
    imag::ExactScalar,
    unit::UnitId,
    orientation::QuantityOrientation;
    base::Union{Nothing,BaseReference} = nothing,
) = ComplexQuantity(real, imag, unit, base, orientation)

Base.:(==)(left::ComplexQuantity, right::ComplexQuantity) =
    left.real == right.real &&
    left.imag == right.imag &&
    left.unit == right.unit &&
    left.base == right.base &&
    left.orientation == right.orientation

function _validate_quantity_metadata(
    registry::UnitRegistry,
    unit_id::UnitId,
    base::Union{Nothing,BaseReference},
    orientation::QuantityOrientation,
)
    unit = lookup_unit(registry, unit_id)
    unit.per_unit == !isnothing(base) || _semantic_fail(
        :invalid_quantity_base,
        unit.per_unit ? "per-unit quantity requires an explicit base reference" : "non-per-unit quantity cannot declare a per-unit base",
    )
    if unit.affine_kind == UnitAbsoluteTemperature
        orientation == OrientationAbsoluteTemperature ||
            _semantic_fail(:invalid_quantity_orientation, "absolute-temperature unit requires absolute-temperature orientation")
    elseif unit.affine_kind == UnitTemperatureDifference
        orientation == OrientationTemperatureDifference ||
            _semantic_fail(:invalid_quantity_orientation, "temperature-difference unit requires temperature-difference orientation")
    elseif orientation in (OrientationAbsoluteTemperature, OrientationTemperatureDifference)
        _semantic_fail(:invalid_quantity_orientation, "temperature orientation requires the corresponding temperature unit kind")
    end
    voltage_dimension = _dimension(2, 1, -3, -1, 0)
    current_dimension = _dimension(0, 0, 0, 1, 0)
    if !unit.per_unit && orientation in (OrientationPhaseToGroundRms, OrientationPhaseToPhaseRms)
        unit.dimension == voltage_dimension || _semantic_fail(:invalid_quantity_orientation, "voltage orientation requires voltage dimension")
    elseif !unit.per_unit && orientation in (OrientationIntoAsset, OrientationOutOfAsset)
        unit.dimension == current_dimension || _semantic_fail(:invalid_quantity_orientation, "current direction requires current dimension")
    end
    return unit
end

function validate_quantity(registry::UnitRegistry, quantity::ScalarQuantity)
    _validate_quantity_metadata(registry, quantity.unit, quantity.base, quantity.orientation)
    return true
end

function validate_quantity(registry::UnitRegistry, quantity::ComplexQuantity)
    unit = _validate_quantity_metadata(registry, quantity.unit, quantity.base, quantity.orientation)
    unit.affine_kind == UnitLinear || _semantic_fail(:invalid_complex_quantity, "complex quantity requires a linear unit")
    return true
end

function convert_quantity(registry::UnitRegistry, quantity::ScalarQuantity, target_id::UnitId)
    validate_quantity(registry, quantity)
    source = lookup_unit(registry, quantity.unit)
    target = lookup_unit(registry, target_id)
    (source.per_unit || target.per_unit) &&
        _semantic_fail(:invalid_unit_conversion, "per-unit conversion requires resolve_per_unit")
    source.dimension == target.dimension || _semantic_fail(:dimension_mismatch, "unit conversion dimensions differ")
    source.affine_kind == target.affine_kind || _semantic_fail(:affine_kind_mismatch, "unit conversion mixes absolute, difference, or linear quantities")
    canonical_value = exact_rational(quantity.value) * source.scale + source.offset
    converted = (canonical_value - target.offset) / target.scale
    result = ScalarQuantity(converted, target_id, quantity.orientation)
    validate_quantity(registry, result)
    return result
end

function resolve_per_unit(
    registry::UnitRegistry,
    quantity::ScalarQuantity,
    base_quantity::ScalarQuantity,
)
    unit = _validate_quantity_metadata(registry, quantity.unit, quantity.base, quantity.orientation)
    unit.per_unit || _semantic_fail(:invalid_per_unit_quantity, "quantity is not per unit")
    validate_quantity(registry, base_quantity)
    isnothing(base_quantity.base) || _semantic_fail(:invalid_per_unit_base, "per-unit base quantity must be physical")
    quantity.orientation == base_quantity.orientation || _semantic_fail(:orientation_mismatch, "per-unit and base orientations differ")
    result = ScalarQuantity(
        exact_rational(quantity.value) * exact_rational(base_quantity.value),
        base_quantity.unit,
        base_quantity.orientation,
    )
    validate_quantity(registry, result)
    return result
end

"""Build AIMORA's minimal exact SI/UCUM unit registry without hidden project defaults."""
function si_unit_registry()
    dimensionless_value = dimensionless()
    length_dimension = _dimension(1, 0, 0, 0, 0)
    mass_dimension = _dimension(0, 1, 0, 0, 0)
    time_dimension = _dimension(0, 0, 1, 0, 0)
    current_dimension = _dimension(0, 0, 0, 1, 0)
    temperature_dimension = _dimension(0, 0, 0, 0, 1)
    frequency_dimension = _dimension(0, 0, -1, 0, 0)
    voltage_dimension = _dimension(2, 1, -3, -1, 0)
    power_dimension = _dimension(2, 1, -3, 0, 0)
    resistance_dimension = _dimension(2, 1, -3, -2, 0)
    return UnitRegistry([
        UnitDefinition(UnitId("%"), dimensionless_value, ExactRational(1, 100)),
        UnitDefinition(UnitId("1"), dimensionless_value, ExactRational(1)),
        UnitDefinition(UnitId("A"), current_dimension, ExactRational(1)),
        UnitDefinition(UnitId("Hz"), frequency_dimension, ExactRational(1)),
        UnitDefinition(UnitId("K"), temperature_dimension, ExactRational(1); affine_kind = UnitAbsoluteTemperature),
        UnitDefinition(UnitId("K_delta"), temperature_dimension, ExactRational(1); affine_kind = UnitTemperatureDifference),
        UnitDefinition(UnitId("Cel"), temperature_dimension, ExactRational(1); offset = ExactRational(27315, 100), affine_kind = UnitAbsoluteTemperature),
        UnitDefinition(UnitId("Cel_delta"), temperature_dimension, ExactRational(1); affine_kind = UnitTemperatureDifference),
        UnitDefinition(UnitId("MVA"), power_dimension, ExactRational(1_000_000)),
        UnitDefinition(UnitId("MW"), power_dimension, ExactRational(1_000_000)),
        UnitDefinition(UnitId("V"), voltage_dimension, ExactRational(1)),
        UnitDefinition(UnitId("W"), power_dimension, ExactRational(1)),
        UnitDefinition(UnitId("kg"), mass_dimension, ExactRational(1)),
        UnitDefinition(UnitId("kV"), voltage_dimension, ExactRational(1_000)),
        UnitDefinition(UnitId("m"), length_dimension, ExactRational(1)),
        UnitDefinition(UnitId("ohm"), resistance_dimension, ExactRational(1)),
        UnitDefinition(UnitId("pu"), dimensionless_value, ExactRational(1); per_unit = true),
        UnitDefinition(UnitId("s"), time_dimension, ExactRational(1)),
    ])
end

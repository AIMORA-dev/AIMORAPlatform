@testset "exact decimal and rational semantics" begin
    @test parse_exact_decimal("123.4500") == ExactDecimal(12345, -2)
    @test parse_exact_decimal("1.2345e2") == ExactDecimal(12345, -2)
    @test parse_exact_decimal("-0.000") == ExactDecimal(0, 0; negative_zero = true)
    @test string(parse_exact_decimal("-0.0")) == "-0e0"
    @test exact_rational(parse_exact_decimal("0.125")) == ExactRational(1, 8)
    @test ExactRational(2, 4) == ExactRational(1, 2)
    @test ExactRational(1, 3) + ExactRational(1, 6) == ExactRational(1, 2)
    @test ExactRational(3, 4) * ExactRational(2, 3) == ExactRational(1, 2)
    @test ExactRational(3, 4) / ExactRational(3, 2) == ExactRational(1, 2)

    for text in ("01", "+1.0", ".5", "1.", "NaN", "Inf", "1_000.0")
        @test semantic_error_code(() -> parse_exact_decimal(text)) == :invalid_exact_decimal
    end
    @test semantic_error_code(() -> ExactRational(1, 0)) == :zero_exact_denominator
    @test semantic_error_code(() -> ExactDecimal(1, 10_001)) == :decimal_exponent_out_of_range
end

@testset "controlled units, bases, orientations, and exact conversion" begin
    units = si_unit_registry()
    @test issorted([unit.id.value for unit in units.units])
    @test lookup_unit(units, UnitId("kV")).scale == ExactRational(1_000)
    @test semantic_error_code(() -> lookup_unit(units, UnitId("unknown"))) == :unknown_unit_id

    voltage = ScalarQuantity(parse_exact_decimal("132.0"), UnitId("kV"), OrientationPhaseToPhaseRms)
    @test validate_quantity(units, voltage)
    volts = convert_quantity(units, voltage, UnitId("V"))
    @test volts == ScalarQuantity(ExactRational(132_000), UnitId("V"), OrientationPhaseToPhaseRms)
    percent = ScalarQuantity(parse_exact_decimal("12.5"), UnitId("%"), OrientationScalar)
    @test convert_quantity(units, percent, UnitId("1")).value == ExactRational(1, 8)

    celsius = ScalarQuantity(parse_exact_decimal("25.0"), UnitId("Cel"), OrientationAbsoluteTemperature)
    @test convert_quantity(units, celsius, UnitId("K")).value == ExactRational(29815, 100)
    difference = ScalarQuantity(parse_exact_decimal("10.0"), UnitId("Cel_delta"), OrientationTemperatureDifference)
    @test convert_quantity(units, difference, UnitId("K_delta")).value == ExactRational(10)
    @test semantic_error_code(() -> convert_quantity(units, celsius, UnitId("K_delta"))) == :affine_kind_mismatch
    @test semantic_error_code(() -> convert_quantity(units, voltage, UnitId("A"))) == :dimension_mismatch

    current = ScalarQuantity(ExactRational(10), UnitId("A"), OrientationIntoAsset)
    @test validate_quantity(units, current)
    wrong_direction = ScalarQuantity(ExactRational(10), UnitId("V"), OrientationIntoAsset)
    @test semantic_error_code(() -> validate_quantity(units, wrong_direction)) == :invalid_quantity_orientation

    base_reference = BaseReference(
        BaseVoltage,
        ProjectReference(ReferenceAsset, ProjectId("generator.G1")),
    )
    per_unit = ScalarQuantity(
        parse_exact_decimal("0.95"),
        UnitId("pu"),
        OrientationPhaseToPhaseRms;
        base = base_reference,
    )
    @test validate_quantity(units, per_unit)
    resolved = resolve_per_unit(units, per_unit, voltage)
    @test resolved == ScalarQuantity(ExactRational(627, 5), UnitId("kV"), OrientationPhaseToPhaseRms)
    missing_base = ScalarQuantity(parse_exact_decimal("0.95"), UnitId("pu"), OrientationScalar)
    @test semantic_error_code(() -> validate_quantity(units, missing_base)) == :invalid_quantity_base
    percent_with_base = ScalarQuantity(parse_exact_decimal("95.0"), UnitId("%"), OrientationScalar; base = base_reference)
    @test semantic_error_code(() -> validate_quantity(units, percent_with_base)) == :invalid_quantity_base

    impedance = ComplexQuantity(
        parse_exact_decimal("0.01"),
        parse_exact_decimal("0.18"),
        UnitId("ohm"),
        OrientationScalar,
    )
    @test validate_quantity(units, impedance)
    invalid_temperature = ComplexQuantity(ExactRational(1), ExactRational(1), UnitId("Cel"), OrientationAbsoluteTemperature)
    @test semantic_error_code(() -> validate_quantity(units, invalid_temperature)) == :invalid_complex_quantity

    duplicate = register_unit(units, lookup_unit(units, UnitId("V")))
    @test duplicate === units
    conflicting = UnitDefinition(UnitId("V"), dimensionless(), ExactRational(1))
    @test semantic_error_code(() -> register_unit(units, conflicting)) == :unit_definition_collision
end

@testset "provenance, uncertainty, and artifact identities are complete" begin
    units = si_unit_registry()
    provenance = canonical_test_provenance()
    voltage = ScalarQuantity(parse_exact_decimal("132.0"), UnitId("kV"), OrientationPhaseToPhaseRms)
    deviation = ScalarQuantity(parse_exact_decimal("1.5"), UnitId("kV"), OrientationPhaseToPhaseRms)
    uncertainty = QuantityUncertainty(
        UncertaintyNormal,
        parse_exact_decimal("0.95");
        standard_deviation = deviation,
    )
    physical = PhysicalValue(voltage, provenance; uncertainty)
    @test validate_quantity(units, physical)
    @test physical.provenance.source_sha256 == repeat("a", 64)
    @test physical.provenance.licence.id == "CC0-1.0"

    lower = ScalarQuantity(parse_exact_decimal("130.0"), UnitId("kV"), OrientationPhaseToPhaseRms)
    upper = ScalarQuantity(parse_exact_decimal("134.0"), UnitId("kV"), OrientationPhaseToPhaseRms)
    interval = QuantityUncertainty(UncertaintyInterval, parse_exact_decimal("1.0"); lower, upper)
    @test interval.lower == lower
    @test semantic_error_code(() -> QuantityUncertainty(UncertaintyNormal, parse_exact_decimal("0.95"))) == :missing_uncertainty_parameter
    @test semantic_error_code(() -> QuantityUncertainty(UncertaintyInterval, parse_exact_decimal("0.0"); lower, upper)) == :invalid_uncertainty_confidence

    mismatched = QuantityUncertainty(
        UncertaintyNormal,
        parse_exact_decimal("0.95");
        standard_deviation = ScalarQuantity(parse_exact_decimal("1500"), UnitId("A"), OrientationIntoAsset),
    )
    @test semantic_error_code(() -> validate_quantity(units, PhysicalValue(voltage, provenance; uncertainty = mismatched))) == :uncertainty_quantity_mismatch

    temperature = ScalarQuantity(parse_exact_decimal("25.0"), UnitId("Cel"), OrientationAbsoluteTemperature)
    temperature_deviation = ScalarQuantity(parse_exact_decimal("1.0"), UnitId("Cel_delta"), OrientationTemperatureDifference)
    temperature_uncertainty = QuantityUncertainty(
        UncertaintyNormal,
        parse_exact_decimal("0.95");
        standard_deviation = temperature_deviation,
    )
    @test validate_quantity(units, PhysicalValue(temperature, provenance; uncertainty = temperature_uncertainty))

    artifact = ArtifactIdentity(
        ProjectId("artifact.weather"),
        "data/weather.parquet",
        repeat("b", 64),
        "application/vnd.apache.parquet",
        provenance;
        schema = SemanticTypeId(NamespaceId("aimora"), ProjectId("data.weather"), v"1.0.0"),
        byte_count = 1024,
    )
    @test artifact.path == "data/weather.parquet"
    @test artifact.byte_count == 1024
    @test semantic_error_code(() -> ArtifactIdentity(ProjectId("artifact.bad"), "../secret", repeat("b", 64), "application/octet-stream", provenance)) == :invalid_artifact_path
    @test semantic_error_code(() -> ArtifactIdentity(ProjectId("artifact.bad"), "data/file", repeat("B", 64), "application/octet-stream", provenance)) == :invalid_artifact_sha256
    @test semantic_error_code(() -> ProvenanceSource(ProjectId("source.bad"), "", canonical_test_licence())) == :missing_provenance_citation
end

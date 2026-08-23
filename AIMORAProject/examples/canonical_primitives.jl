using AIMORAProject
using UUIDs

function build_canonical_primitive_example()
    units = si_unit_registry()
    licence = LicenceIdentity(
        "CC0-1.0",
        "CC0 1.0 Universal";
        uri = GlobalId("https://creativecommons.org/publicdomain/zero/1.0/"),
    )
    provenance = ProvenanceSource(
        ProjectId("source.public_example"),
        "AIMORA synthetic canonical-primitives example",
        licence;
        source_version = "1.0.0",
    )

    namespace = NamespaceId("aimora")
    registry = register_namespace(
        SemanticSchemaRegistry(),
        NamespaceRegistration(
            namespace,
            UUID("1867e578-e373-4a38-a813-9703fe6c30ba"),
            licence,
            provenance,
        ),
    )
    voltage_field = SchemaField(
        "nominal_voltage",
        SchemaQuantity;
        required = true,
        constraints = [QuantityConstraint(
            lookup_unit(units, UnitId("V")).dimension,
            [OrientationPhaseToGroundRms, OrientationPhaseToPhaseRms];
            allow_per_unit = true,
        )],
    )
    schema = SemanticSchema(
        SemanticSchemaIdentity(
            UUID("9475cb4e-713d-4691-9c65-a81374d51d96"),
            namespace,
            ProjectId("asset.bus"),
            v"1.0.0",
        ),
        [SchemaField("id", SchemaString; required = true), voltage_field],
        provenance,
    )
    registry = register_schema(registry, schema)

    voltage = PhysicalValue(
        ScalarQuantity(
            parse_exact_decimal("132.0"),
            UnitId("kV"),
            OrientationPhaseToPhaseRms,
        ),
        provenance,
    )
    validate_field_value(voltage_field, voltage, units)
    volts = convert_quantity(units, voltage.quantity, UnitId("V"))
    println("schema ", schema.identity.name.value, " validates ", volts.value.numerator, " V exactly")
    return (units = units, registry = registry, schema = schema, voltage = voltage)
end

build_canonical_primitive_example()

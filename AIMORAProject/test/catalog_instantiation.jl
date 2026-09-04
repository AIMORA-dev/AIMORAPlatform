@testset "catalog assembly materialization and parts schedule" begin
    breaker_id = GlobalId("aimora://catalog/system/switching.circuit_breaker@1.0.0")
    bus_id = GlobalId("aimora://catalog/system/power.busbar@1.0.0")
    cable_id = GlobalId("aimora://catalog/system/network.cable@1.0.0")
    members = [
        CatalogAssemblyMemberSpec(
            ProjectId("bus"),
            bus_id,
            "power.busbar",
            "B",
            [CatalogPartLine("AIM-BUS", "Busbar section", "item", 1)],
        ),
        CatalogAssemblyMemberSpec(
            ProjectId("breaker"),
            breaker_id,
            "switching.circuit_breaker",
            "Q",
            [CatalogPartLine("AIM-CB", "Circuit breaker", "item", 1)];
            parent_local_id = ProjectId("bus"),
            cross_references = [
                CatalogCrossReferenceSpec("upstream", ProjectId("bus")),
            ],
        ),
    ]
    assembly = CatalogAssemblySpec(
        GlobalId("aimora://catalog/system/assembly.feeder_bay@1.0.0"),
        members,
    )
    materialized = materialize_catalog_assembly(
        assembly,
        ProjectId("bay.feeder01");
        occupied_designators = ["B1", "Q1"],
    )
    @test getfield.(materialized.members, :designator) == ["Q2", "B2"]
    @test materialized.members[1].parent_instance_id == ProjectId("bay.feeder01.bus")
    @test only(materialized.members[1].cross_references).target_instance_id ==
          ProjectId("bay.feeder01.bus")
    @test length(unique(getfield.(getfield.(materialized.members, :identity), :uid))) == 2
    @test length(catalog_parts_schedule(materialized)) == 2

    @test semantic_error_code(() -> materialize_catalog_assembly(
        assembly,
        ProjectId("bay.feeder01");
        occupied_project_ids = [ProjectId("bay.feeder01.breaker")],
    )) == :catalog_instance_id_conflict
    @test semantic_error_code(() -> CatalogAssemblySpec(
        assembly.id,
        [
            members[1],
            CatalogAssemblyMemberSpec(
                ProjectId("invalid"),
                cable_id,
                "network.cable",
                "W",
                [CatalogPartLine("AIM-CABLE", "Power cable", "m", 1)];
                parent_local_id = ProjectId("missing"),
            ),
        ],
    )) == :unknown_catalog_parent
end

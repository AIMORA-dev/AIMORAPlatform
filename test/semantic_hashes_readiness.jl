function project_with_records(project::CanonicalProject, records)
    return unsafe_project(
        project.metadata,
        project.registry,
        project.units,
        records,
        project.graphs,
        project.asset_library,
        project.hierarchy,
        project.control_system,
        project.event_scenarios,
        project.orchestration,
    )
end

@testset "semantic canonicalization separates source resolved physics view and execution" begin
    fixture = ORCHESTRATION_FIXTURE
    project = fixture.project
    execution = ExecutionDependencySignatures(
        ContentDigest(repeat("1", 64)),
        ContentDigest(repeat("2", 64)),
        ContentDigest(repeat("3", 64)),
    )
    source = ContentDigest(repeat("4", 64))
    hashes = project_semantic_hashes(project, source, execution)
    equivalent = unsafe_project(
        project.metadata,
        project.registry,
        project.units,
        reverse(collect(project.records)),
        project.graphs,
        AssetLibrary(
            assets = reverse(collect(project.asset_library.assets)),
            profiles = reverse(collect(project.asset_library.profiles)),
            curves = reverse(collect(project.asset_library.curves)),
            matrices = reverse(collect(project.asset_library.matrices)),
            measurements = reverse(collect(project.asset_library.measurements)),
        ),
        project.hierarchy,
        project.control_system,
        project.event_scenarios,
        OrchestrationModel(
            study_schemas = reverse(collect(project.orchestration.study_schemas)),
            studies = reverse(collect(project.orchestration.studies)),
            result_contracts = reverse(collect(project.orchestration.result_contracts)),
            results = reverse(collect(project.orchestration.results)),
            workflows = reverse(collect(project.orchestration.workflows)),
            experiments = reverse(collect(project.orchestration.experiments)),
        ),
    )
    @test project_resolved_hash(equivalent) == hashes.resolved
    @test project_physics_hash(equivalent) == hashes.physics
    @test project_view_hash(equivalent) == hashes.view

    record = project_record(project, ProjectId("bus.HV"))
    fields = CanonicalField[
        field.name == "nominal_voltage" ? CanonicalField(
            "nominal_voltage",
            PhysicalValue(
                ScalarQuantity(parse_exact_decimal("132000.0"), UnitId("V"), OrientationPhaseToPhaseRms),
                fixture.provenance,
            ),
        ) : field
        for field in record.fields
    ]
    normalized_record = CanonicalRecord(record.identity, record.schema, fields, record.provenance)
    normalized_records = CanonicalRecord[
        item.identity.id == record.identity.id ? normalized_record : item for item in project.records
    ]
    unit_equivalent = project_with_records(project, normalized_records)
    @test project_resolved_hash(unit_equivalent) == hashes.resolved
    @test project_physics_hash(unit_equivalent) == hashes.physics
    @test scenario_content_hash(unit_equivalent, fixture.event_fixture.peak.identity.id) ==
        scenario_content_hash(project, fixture.event_fixture.peak.identity.id)

    renamed_metadata = ProjectMetadata(
        project.metadata.identity,
        "Renamed Project",
        project.metadata.default_namespace,
        project.metadata.format_version,
        project.metadata.created_at_utc,
        project.metadata.provenance,
    )
    renamed = unsafe_project(
        renamed_metadata,
        project.registry,
        project.units,
        collect(project.records),
        project.graphs,
        project.asset_library,
        project.hierarchy,
        project.control_system,
        project.event_scenarios,
        project.orchestration,
    )
    @test project_resolved_hash(renamed) != hashes.resolved
    @test project_physics_hash(renamed) == hashes.physics
    @test scenario_content_hash(renamed, fixture.event_fixture.peak.identity.id) ==
        scenario_content_hash(project, fixture.event_fixture.peak.identity.id)

    original_asset = canonical_asset(project, ProjectId("bus.HV"))
    public_asset = CanonicalAsset(
        original_asset.identity,
        original_asset.asset_type,
        collect(original_asset.common),
        collect(original_asset.realizations),
        original_asset.provenance;
        catalog = original_asset.catalog,
        overrides = collect(original_asset.overrides),
        access = AccessPublic,
    )
    access_project = unsafe_project(
        project.metadata,
        project.registry,
        project.units,
        collect(project.records),
        project.graphs,
        AssetLibrary(
            assets = [public_asset],
            profiles = collect(project.asset_library.profiles),
            curves = collect(project.asset_library.curves),
            matrices = collect(project.asset_library.matrices),
            measurements = collect(project.asset_library.measurements),
        ),
        project.hierarchy,
        project.control_system,
        project.event_scenarios,
        project.orchestration,
    )
    @test project_physics_hash(access_project) == hashes.physics
    @test project_resolved_hash(access_project) != hashes.resolved

    changed_source = project_semantic_hashes(project, ContentDigest(repeat("5", 64)), execution)
    @test changed_source.source != hashes.source
    @test changed_source.resolved == hashes.resolved
    @test changed_source.physics == hashes.physics
    @test changed_source.view == hashes.view
    changed_execution = project_semantic_hashes(
        project,
        source,
        ExecutionDependencySignatures(
            execution.automation_environment,
            ContentDigest(repeat("6", 64)),
            execution.script_environment,
        ),
    )
    @test changed_execution.execution != hashes.execution
    @test changed_execution.resolved == hashes.resolved
    @test result_dependency_hash(project, fixture.accepted_emt) !=
        result_dependency_hash(project, fixture.accepted_power_flow)
    dependency = result_dependency_signature(
        project,
        fixture.emt,
        execution,
        [result_dependency_hash(project, fixture.accepted_power_flow)],
    )
    changed_plugin_dependency = result_dependency_signature(
        project,
        fixture.emt,
        ExecutionDependencySignatures(
            execution.automation_environment,
            ContentDigest(repeat("7", 64)),
            execution.script_environment,
        ),
        [result_dependency_hash(project, fixture.accepted_power_flow)],
    )
    changed_upstream_dependency = result_dependency_signature(
        project,
        fixture.emt,
        execution,
        [ContentDigest(repeat("8", 64))],
    )
    @test result_dependency_hash(dependency) != result_dependency_hash(changed_plugin_dependency)
    @test result_dependency_hash(dependency) != result_dependency_hash(changed_upstream_dependency)
    changed_fields = CanonicalField[
        field.name == "nominal_voltage" ? CanonicalField(
            "nominal_voltage",
            PhysicalValue(
                ScalarQuantity(parse_exact_decimal("133000.0"), UnitId("V"), OrientationPhaseToPhaseRms),
                fixture.provenance,
            ),
        ) : field
        for field in record.fields
    ]
    changed_record = CanonicalRecord(record.identity, record.schema, changed_fields, record.provenance)
    changed_model_project = project_with_records(
        project,
        CanonicalRecord[item.identity.id == record.identity.id ? changed_record : item for item in project.records],
    )
    changed_model_dependency = result_dependency_signature(
        changed_model_project,
        fixture.emt,
        execution,
        [result_dependency_hash(project, fixture.accepted_power_flow)],
    )
    changed_study = StudyRequest(
        fixture.emt.identity,
        fixture.emt.schema,
        fixture.emt.project_revision,
        fixture.emt.scenario,
        fixture.emt.representation,
        fixture.emt.fidelity,
        fixture.emt.method,
        [CanonicalField("timestep", fixture.physical("10.0e-6", "s"))],
        collect(fixture.emt.initialization),
        collect(fixture.emt.events),
        collect(fixture.emt.outputs),
        collect(fixture.emt.prerequisites),
        fixture.emt.validity,
        fixture.provenance,
    )
    changed_study_dependency = result_dependency_signature(
        project,
        changed_study,
        execution,
        [result_dependency_hash(project, fixture.accepted_power_flow)],
    )
    @test result_dependency_hash(dependency) != result_dependency_hash(changed_model_dependency)
    @test result_dependency_hash(dependency) != result_dependency_hash(changed_study_dependency)
end

@testset "view-only changes preserve physics and result cache is reconstructible" begin
    fixture = ORCHESTRATION_FIXTURE
    project = fixture.project
    function with_projection(id)
        projection = ViewProjection(
            ObjectIdentity(ProjectId(id)),
            ProjectId("bus.MV"),
            ProjectId("bus.HV"),
            fixture.provenance,
        )
        graphs = SemanticGraphs(
            nodes = collect(project.graphs.nodes),
            ports = collect(project.graphs.ports),
            physical_connections = collect(project.graphs.physical_connections),
            signal_connections = collect(project.graphs.signal_connections),
            workflow_dependencies = collect(project.graphs.workflow_dependencies),
            cross_references = collect(project.graphs.cross_references),
            view_projections = [projection],
        )
        return unsafe_project(
            project.metadata,
            project.registry,
            project.units,
            collect(project.records),
            graphs,
            project.asset_library,
            project.hierarchy,
            project.control_system,
            project.event_scenarios,
            project.orchestration,
        )
    end
    first_view = with_projection("projection.first")
    second_view = with_projection("projection.second")
    @test project_physics_hash(first_view) == project_physics_hash(second_view)
    @test project_view_hash(first_view) != project_view_hash(second_view)

    no_cache = without_result_cache(project)
    @test no_cache.verification == ProjectVerified
    @test isempty(no_cache.orchestration.results)
    @test project_resolved_hash(no_cache) == project_resolved_hash(project)
    @test project_physics_hash(no_cache) == project_physics_hash(project)
    @test without_result_cache(no_cache) === no_cache
end

@testset "study readiness reports exact missing optional realization and prerequisite reasons" begin
    fixture = ORCHESTRATION_FIXTURE
    power_flow = study_readiness(fixture.project, fixture.power_flow.identity.id)
    emt = study_readiness(fixture.project, fixture.emt.identity.id)
    @test power_flow.state == StudyReady
    @test isempty(power_flow.reasons)
    @test emt.state == StudyReady
    @test isempty(emt.reasons)

    no_cache = without_result_cache(fixture.project)
    pending = study_readiness(no_cache, fixture.emt.identity.id)
    @test pending.state == StudyReadyWithWarnings
    @test [item.code for item in pending.reasons] == [AutomaticPrerequisitePending]
    @test isempty(missing_requirements(pending))

    incomplete = StudyRequest(
        fixture.power_flow.identity,
        fixture.power_flow.schema,
        fixture.power_flow.project_revision,
        fixture.power_flow.scenario,
        fixture.power_flow.representation,
        fixture.power_flow.fidelity,
        fixture.power_flow.method,
        CanonicalField[],
        collect(fixture.power_flow.initialization),
        collect(fixture.power_flow.events),
        collect(fixture.power_flow.outputs),
        collect(fixture.power_flow.prerequisites),
        fixture.power_flow.validity,
        fixture.provenance,
    )
    incomplete_model = OrchestrationModel(
        study_schemas = collect(fixture.model.study_schemas),
        studies = [incomplete, fixture.emt],
        result_contracts = collect(fixture.model.result_contracts),
        results = ResultDeclaration[],
        workflows = WorkflowDefinition[],
    )
    incomplete_project = unsafe_project(
        fixture.project.metadata,
        fixture.project.registry,
        fixture.project.units,
        collect(fixture.project.records),
        fixture.project.graphs,
        fixture.project.asset_library,
        fixture.project.hierarchy,
        fixture.project.control_system,
        fixture.project.event_scenarios,
        incomplete_model,
    )
    report = study_readiness(incomplete_project, incomplete.identity.id)
    @test report.state == StudyBlocked
    @test [item.code for item in missing_requirements(report)] == [MissingRequiredSetting]

    optional_schema = StudyRequestSchema(
        fixture.power_flow_schema.identity,
        collect(fixture.power_flow_schema.representations),
        collect(fixture.power_flow_schema.fidelities),
        vcat(
            collect(fixture.power_flow_schema.settings),
            [SchemaField("report_detail", SchemaString)],
        ),
        collect(fixture.power_flow_schema.initialization),
        fixture.provenance,
    )
    optional_model = OrchestrationModel(
        study_schemas = [optional_schema, fixture.emt_schema],
        studies = [fixture.power_flow, fixture.emt],
        result_contracts = collect(fixture.model.result_contracts),
        results = collect(fixture.model.results),
        workflows = collect(fixture.model.workflows),
        experiments = collect(fixture.model.experiments),
    )
    optional_project = unsafe_project(
        fixture.project.metadata,
        fixture.project.registry,
        fixture.project.units,
        collect(fixture.project.records),
        fixture.project.graphs,
        fixture.project.asset_library,
        fixture.project.hierarchy,
        fixture.project.control_system,
        fixture.project.event_scenarios,
        optional_model,
    )
    optional_report = study_readiness(optional_project, fixture.power_flow.identity.id)
    @test optional_report.state == StudyReadyWithWarnings
    @test [item.code for item in optional_report.reasons] == [MissingOptionalSetting]

    unsupported = StudyRequest(
        fixture.emt.identity,
        fixture.emt.schema,
        fixture.emt.project_revision,
        fixture.emt.scenario,
        fixture.emt.representation,
        FieldCoupledDetailed,
        fixture.emt.method,
        collect(fixture.emt.settings),
        collect(fixture.emt.initialization),
        collect(fixture.emt.events),
        collect(fixture.emt.outputs),
        StudyPrerequisite[],
        fixture.emt.validity,
        fixture.provenance,
    )
    unsupported_model = OrchestrationModel(
        study_schemas = collect(fixture.model.study_schemas),
        studies = [fixture.power_flow, unsupported],
        result_contracts = collect(fixture.model.result_contracts),
        workflows = WorkflowDefinition[],
    )
    unsupported_project = unsafe_project(
        fixture.project.metadata,
        fixture.project.registry,
        fixture.project.units,
        collect(fixture.project.records),
        fixture.project.graphs,
        fixture.project.asset_library,
        fixture.project.hierarchy,
        fixture.project.control_system,
        fixture.project.event_scenarios,
        unsupported_model,
    )
    unsupported_report = study_readiness(unsupported_project, unsupported.identity.id)
    @test unsupported_report.state == StudyBlocked
    @test UnsupportedStudyFidelity in [item.code for item in missing_requirements(unsupported_report)]
    @test MissingExactRealization in [item.code for item in missing_requirements(unsupported_report)]

    valid_layers = validate_project_layers(fixture.project)
    @test all(item -> item.passed, valid_layers)
    incomplete_layers = validate_project_layers(incomplete_project)
    orchestration_layer = only(item for item in incomplete_layers if item.layer == ValidationStudiesWorkflows)
    @test !orchestration_layer.passed
    @test orchestration_layer.error_code == :missing_study_setting
end

@testset "dependency impact follows exact study result workflow and experiment consumers" begin
    fixture = ORCHESTRATION_FIXTURE
    impact = dependency_impact(fixture.project, ProjectId("bus.HV"))
    downstream = Set(impact.downstream)
    @test fixture.power_flow.identity.id in downstream
    @test fixture.emt.identity.id in downstream
    @test fixture.accepted_power_flow.identity.id in downstream
    @test fixture.accepted_emt.identity.id in downstream
    @test fixture.workflow.identity.id in downstream
    @test fixture.sweep.identity.id in downstream
    @test all(item.owner in downstream for item in impact.invalidations)
    @test [item.value for item in impact.roots] == ["bus.HV"]
    @test semantic_error_code(() -> dependency_impact(fixture.project, ProjectId[])) == :empty_dependency_roots
end

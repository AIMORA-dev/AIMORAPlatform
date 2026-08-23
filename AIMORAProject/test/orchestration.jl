function orchestration_fixture()
    event_fixture = event_scenario_fixture()
    project = event_fixture.project
    provenance = event_fixture.provenance
    namespace = NamespaceId("aimora")
    semantic_type(name) = SemanticTypeId(namespace, ProjectId(name), v"1.0.0")
    schema_identity(name, uuid) = SemanticSchemaIdentity(UUID(uuid), namespace, ProjectId(name), v"1.0.0")
    function_identity(symbol, digit) = RegisteredFunctionIdentity(
        UUID("4c76537d-5348-4f3c-9304-3a1a594296df"),
        semantic_type("package.orchestration_test"),
        ProjectId(symbol),
        ContentDigest(repeat(digit, 64)),
    )
    physical(value, unit, orientation = OrientationScalar) = PhysicalValue(
        ScalarQuantity(parse_exact_decimal(value), UnitId(unit), orientation),
        provenance,
    )
    seconds_field = SchemaField(
        "timestep",
        SchemaQuantity;
        required = true,
        constraints = [QuantityConstraint(
            lookup_unit(project.units, UnitId("s")).dimension,
            [OrientationScalar],
        )],
    )
    tolerance_field = SchemaField(
        "tolerance",
        SchemaDecimal;
        required = true,
        constraints = [NumericBoundsConstraint(lower = ExactRational(0))],
    )
    voltage_field = SchemaField(
        "voltage",
        SchemaQuantity;
        required = true,
        constraints = [QuantityConstraint(
            lookup_unit(project.units, UnitId("kV")).dimension,
            [OrientationPhaseToPhaseRms],
        )],
    )
    current_field = SchemaField(
        "current",
        SchemaQuantity;
        required = true,
        constraints = [QuantityConstraint(
            lookup_unit(project.units, UnitId("A")).dimension,
            [OrientationIntoAsset],
        )],
    )
    power_flow_schema = StudyRequestSchema(
        schema_identity("study.power_flow", "9f6afdf4-a143-459d-a951-3f9c49cc8892"),
        [StaticPhasor],
        [AverageValue],
        [tolerance_field],
        SchemaField[],
        provenance,
    )
    emt_schema = StudyRequestSchema(
        schema_identity("study.emt", "21d0135c-da79-472f-99f0-67ee715377c8"),
        [InstantaneousEMT],
        [SwitchingDetailed],
        [seconds_field],
        [voltage_field],
        provenance,
    )
    operating_contract = ResultContract(
        schema_identity("result.operating_point", "ff8a460a-2a90-46ff-b74a-93b18ca0471b"),
        [voltage_field],
        provenance,
    )
    fault_contract = ResultContract(
        schema_identity("result.fault_current", "83d72a77-c4ca-46c7-b507-fde50cd2dfba"),
        [current_field],
        provenance,
    )
    revision_hash = ContentDigest(repeat("b", 64))
    power_flow = StudyRequest(
        ObjectIdentity(ProjectId("study.base_power_flow")),
        power_flow_schema.identity,
        revision_hash,
        nothing,
        StaticPhasor,
        AverageValue,
        StudyMethodDeclaration(
            semantic_type("method.newton_raphson"),
            function_identity("solve_power_flow", "1"),
            CanonicalField[],
        ),
        [CanonicalField("tolerance", parse_exact_decimal("1.0e-8"))],
        CanonicalField[],
        ProjectReference[],
        [StudyOutputRequest(
            ObjectIdentity(ProjectId("output.bus_voltage")),
            operating_contract.identity,
            ProjectReference(ReferenceAsset, ProjectId("bus.HV")),
            semantic_type("quantity.voltage"),
            UnitId("kV"),
            OrientationPhaseToPhaseRms,
            provenance,
        )],
        StudyPrerequisite[],
        StudyValidityPolicy(StudyOutsideDomainError, StudyOptionalDataWarning),
        provenance,
    )
    emt = StudyRequest(
        ObjectIdentity(ProjectId("study.fault_emt")),
        emt_schema.identity,
        revision_hash,
        ProjectReference(ReferenceScenario, event_fixture.peak.identity.id),
        InstantaneousEMT,
        SwitchingDetailed,
        StudyMethodDeclaration(
            semantic_type("method.trapezoidal"),
            function_identity("solve_emt", "2"),
            [CanonicalField("event_localization", "safeguarded")],
        ),
        [CanonicalField("timestep", physical("20.0e-6", "s"))],
        [CanonicalField("voltage", physical("132.0", "kV", OrientationPhaseToPhaseRms))],
        [ProjectReference(ReferenceEvent, event_fixture.fault.identity.id)],
        [StudyOutputRequest(
            ObjectIdentity(ProjectId("output.fault_current")),
            fault_contract.identity,
            ProjectReference(ReferenceAsset, ProjectId("bus.HV")),
            semantic_type("quantity.current"),
            UnitId("A"),
            OrientationIntoAsset,
            provenance,
        )],
        [StudyPrerequisite(
            ObjectIdentity(ProjectId("prerequisite.operating_point")),
            ProjectReference(ReferenceStudy, power_flow.identity.id),
            true,
            operating_contract.identity,
            provenance,
        )],
        StudyValidityPolicy(StudyOutsideDomainError, StudyOptionalDataWarning),
        provenance,
    )
    accepted_power_flow = ResultDeclaration(
        ObjectIdentity(ProjectId("result.base_power_flow")),
        operating_contract.identity,
        ProjectReference(ReferenceStudy, power_flow.identity.id),
        revision_hash,
        nothing,
        study_request_hash(power_flow),
        ContentDigest[],
        provenance,
    )
    accepted_emt = ResultDeclaration(
        ObjectIdentity(ProjectId("result.fault_emt")),
        fault_contract.identity,
        ProjectReference(ReferenceStudy, emt.identity.id),
        revision_hash,
        scenario_content_hash(project, event_fixture.peak.identity.id),
        study_request_hash(emt),
        [study_request_hash(power_flow)],
        provenance,
    )
    power_flow_step = WorkflowStep(
        ObjectIdentity(ProjectId("step.power_flow")),
        ProjectReference(ReferenceStudy, power_flow.identity.id),
        ProjectId[],
        WorkflowInputBinding[],
        provenance,
    )
    emt_step = WorkflowStep(
        ObjectIdentity(ProjectId("step.emt")),
        ProjectReference(ReferenceStudy, emt.identity.id),
        [power_flow_step.identity.id],
        [WorkflowInputBinding(
            "operating_point",
            StepResultSource(power_flow_step.identity.id, operating_contract.identity),
            true,
        )],
        provenance,
    )
    workflow = WorkflowDefinition(
        ObjectIdentity(ProjectId("workflow.fault_review")),
        [emt_step, power_flow_step],
        WorkflowStopOnFailure,
        WorkflowUseValidCache,
        provenance,
    )
    execution = ExperimentExecution(
        ExperimentParallelDeterministic,
        2,
        184467,
        semantic_type("rng.stable"),
    )
    checkpoint = ExperimentCheckpoint(semantic_type("checkpoint.experiment"), 1, 3, true)
    policies = ExperimentPolicies(ExperimentStopOnFailure, ExperimentUseValidCache)
    stopping = ExperimentStoppingCriteria(
        40,
        200,
        parse_exact_decimal("1.0e-8"),
        5,
        function_identity("converged", "3"),
        ExperimentTerminationReport,
        ExperimentTerminationError,
    )
    solver = ExperimentSolverDeclaration(
        function_identity("optimize", "4"),
        [CanonicalField("algorithm", "bounded_test_solver")],
    )
    function decision_variable(id; candidates = PhysicalValue{ScalarQuantity}[])
        return DecisionVariable(
            ObjectIdentity(ProjectId(id)),
            ProjectReference(ReferenceAsset, ProjectId("bus.HV")),
            FieldPath("nameplate.rating"),
            UnitId("MVA"),
            OrientationScalar,
            DecisionContinuous,
            physical("80.0", "MVA"),
            physical("120.0", "MVA"),
            candidates,
            provenance,
        )
    end
    function objective(id)
        return ObjectiveDeclaration(
            ObjectIdentity(ProjectId(id)),
            ResultSelector(fault_contract.identity, FieldPath("current"), UnitId("A"), OrientationIntoAsset),
            function_identity("objective_fault_current", "5"),
            ObjectiveMinimize,
            parse_exact_decimal("1.0"),
            provenance,
        )
    end
    function constraint(id)
        return ConstraintDeclaration(
            ObjectIdentity(ProjectId(id)),
            ResultSelector(fault_contract.identity, FieldPath("current"), UnitId("A"), OrientationIntoAsset),
            function_identity("constraint_fault_current", "6"),
            nothing,
            physical("25000.0", "A", OrientationIntoAsset),
            provenance,
        )
    end
    evaluation = ProjectReference(ReferenceWorkflow, workflow.identity.id)
    sweep = ParameterSweepExperiment(
        ObjectIdentity(ProjectId("experiment.rating_sweep")),
        [decision_variable(
            "variable.sweep_rating";
            candidates = [physical("90.0", "MVA"), physical("100.0", "MVA"), physical("110.0", "MVA")],
        )],
        evaluation,
        execution,
        checkpoint,
        policies,
        provenance,
    )
    iteration = BoundedIterationExperiment(
        ObjectIdentity(ProjectId("experiment.rating_iteration")),
        [decision_variable("variable.iteration_rating")],
        function_identity("update_rating", "7"),
        evaluation,
        stopping,
        execution,
        checkpoint,
        policies,
        provenance,
    )
    calibration = CalibrationExperiment(
        ObjectIdentity(ProjectId("experiment.rating_calibration")),
        [decision_variable("variable.calibration_rating")],
        [objective("objective.calibration_current")],
        [constraint("constraint.calibration_current")],
        evaluation,
        solver,
        stopping,
        execution,
        checkpoint,
        policies,
        provenance,
    )
    uncertainty = QuantityUncertainty(
        UncertaintyNormal,
        parse_exact_decimal("0.95");
        standard_deviation = ScalarQuantity(parse_exact_decimal("2.0"), UnitId("MVA"), OrientationScalar),
    )
    uncertainty_experiment = UncertaintyExperiment(
        ObjectIdentity(ProjectId("experiment.rating_uncertainty")),
        [UncertainInput(decision_variable("variable.uncertain_rating"), uncertainty)],
        100,
        function_identity("sample_rating", "8"),
        evaluation,
        execution,
        checkpoint,
        policies,
        provenance,
    )
    optimization = OptimizationExperiment(
        ObjectIdentity(ProjectId("experiment.rating_optimization")),
        [decision_variable("variable.optimization_rating")],
        [objective("objective.optimization_current")],
        [constraint("constraint.optimization_current")],
        evaluation,
        solver,
        stopping,
        execution,
        checkpoint,
        policies,
        provenance,
    )
    model = OrchestrationModel(
        study_schemas = [emt_schema, power_flow_schema],
        studies = [emt, power_flow],
        result_contracts = [fault_contract, operating_contract],
        results = [accepted_power_flow, accepted_emt],
        workflows = [workflow],
        experiments = [sweep, iteration, calibration, uncertainty_experiment, optimization],
    )
    canonical_project = CanonicalProject(
        project.metadata,
        project.registry,
        project.units,
        collect(project.records),
        project.graphs,
        project.asset_library,
        project.hierarchy,
        project.control_system,
        project.event_scenarios,
        model,
    )
    return (;
        event_fixture,
        provenance,
        semantic_type,
        function_identity,
        physical,
        power_flow_schema,
        emt_schema,
        operating_contract,
        fault_contract,
        revision_hash,
        power_flow,
        emt,
        accepted_power_flow,
        accepted_emt,
        power_flow_step,
        emt_step,
        workflow,
        execution,
        checkpoint,
        policies,
        stopping,
        solver,
        decision_variable,
        objective,
        constraint,
        sweep,
        iteration,
        calibration,
        uncertainty_experiment,
        optimization,
        model,
        project = canonical_project,
    )
end

const ORCHESTRATION_FIXTURE = orchestration_fixture()

@testset "typed studies results workflows and bounded experiments validate" begin
    fixture = ORCHESTRATION_FIXTURE
    example_module = Module(:StudyWorkflowExample, true, true)
    example = Base.include(example_module, joinpath(@__DIR__, "..", "examples", "study_workflow.jl"))
    @test example.project.verification == ProjectVerified
    @test length(example.project.orchestration.experiments) == 1
    @test example.readiness.state == StudyReady
    @test validate_orchestration(fixture.project)
    @test study_request(fixture.project.orchestration, fixture.emt.identity.id) == fixture.emt
    @test result_declaration(fixture.project.orchestration, fixture.accepted_power_flow.identity.id) == fixture.accepted_power_flow
    @test result_declaration(fixture.project.orchestration, fixture.accepted_emt.identity.id) == fixture.accepted_emt
    @test scenario_content_hash(fixture.project, fixture.event_fixture.peak.identity.id) == fixture.accepted_emt.scenario_hash
    @test workflow_definition(fixture.project.orchestration, fixture.workflow.identity.id) == fixture.workflow
    @test [typeof(item) for item in fixture.project.orchestration.experiments] == [
        CalibrationExperiment,
        BoundedIterationExperiment,
        OptimizationExperiment,
        ParameterSweepExperiment,
        UncertaintyExperiment,
    ]
    @test fixture.execution.order == ExperimentParallelDeterministic
    @test fixture.execution.seed == UInt64(184467)
    @test fixture.checkpoint.resume
    @test fixture.stopping.on_stagnation == ExperimentTerminationReport
    @test fixture.stopping.on_infeasible == ExperimentTerminationError
end

@testset "study and workflow contracts reject owner drift cycles and stale results" begin
    fixture = ORCHESTRATION_FIXTURE
    function project_with(; studies = collect(fixture.model.studies), results = collect(fixture.model.results), workflows = collect(fixture.model.workflows))
        return unsafe_project(
            fixture.project.metadata,
            fixture.project.registry,
            fixture.project.units,
            collect(fixture.project.records),
            fixture.project.graphs,
            fixture.project.asset_library,
            fixture.project.hierarchy,
            fixture.project.control_system,
            fixture.project.event_scenarios,
            OrchestrationModel(
                study_schemas = collect(fixture.model.study_schemas),
                studies = studies,
                result_contracts = collect(fixture.model.result_contracts),
                results = results,
                workflows = workflows,
            ),
        )
    end
    unrelated = StudyRequest(
        fixture.power_flow.identity,
        fixture.power_flow.schema,
        fixture.revision_hash,
        nothing,
        fixture.power_flow.representation,
        fixture.power_flow.fidelity,
        fixture.power_flow.method,
        [CanonicalField("timestep", fixture.physical("1.0e-3", "s"))],
        CanonicalField[],
        ProjectReference[],
        collect(fixture.power_flow.outputs),
        StudyPrerequisite[],
        fixture.power_flow.validity,
        fixture.provenance,
    )
    bad_owner = unsafe_project(
        fixture.project.metadata,
        fixture.project.registry,
        fixture.project.units,
        collect(fixture.project.records),
        fixture.project.graphs,
        fixture.project.asset_library,
        fixture.project.hierarchy,
        fixture.project.control_system,
        fixture.project.event_scenarios,
        OrchestrationModel(
            study_schemas = collect(fixture.model.study_schemas),
            studies = [fixture.emt, unrelated],
            result_contracts = collect(fixture.model.result_contracts),
            results = collect(fixture.model.results),
            workflows = collect(fixture.model.workflows),
            experiments = collect(fixture.model.experiments),
        ),
    )
    @test semantic_error_code(() -> validate_orchestration(bad_owner)) == :unknown_study_setting

    stale = ResultDeclaration(
        fixture.accepted_power_flow.identity,
        fixture.accepted_power_flow.contract,
        fixture.accepted_power_flow.producer,
        fixture.revision_hash,
        nothing,
        ContentDigest(repeat("e", 64)),
        ContentDigest[],
        fixture.provenance,
    )
    stale_project = project_with(results = [stale], workflows = WorkflowDefinition[])
    @test semantic_error_code(() -> validate_orchestration(stale_project)) == :stale_result_study_request

    stale_revision = ResultDeclaration(
        fixture.accepted_power_flow.identity,
        fixture.accepted_power_flow.contract,
        fixture.accepted_power_flow.producer,
        ContentDigest(repeat("f", 64)),
        nothing,
        study_request_hash(fixture.power_flow),
        ContentDigest[],
        fixture.provenance,
    )
    @test semantic_error_code(() -> validate_orchestration(project_with(
        results = [stale_revision],
        workflows = WorkflowDefinition[],
    ))) == :stale_result_project_revision

    stale_scenario = ResultDeclaration(
        fixture.accepted_power_flow.identity,
        fixture.accepted_power_flow.contract,
        fixture.accepted_power_flow.producer,
        fixture.revision_hash,
        ContentDigest(repeat("9", 64)),
        study_request_hash(fixture.power_flow),
        ContentDigest[],
        fixture.provenance,
    )
    @test semantic_error_code(() -> validate_orchestration(project_with(
        results = [stale_scenario],
        workflows = WorkflowDefinition[],
    ))) == :stale_result_scenario

    incompatible = ResultDeclaration(
        fixture.accepted_power_flow.identity,
        fixture.fault_contract.identity,
        fixture.accepted_power_flow.producer,
        fixture.revision_hash,
        nothing,
        study_request_hash(fixture.power_flow),
        ContentDigest[],
        fixture.provenance,
    )
    @test semantic_error_code(() -> validate_orchestration(project_with(
        results = [incompatible],
        workflows = WorkflowDefinition[],
    ))) == :incompatible_result_contract

    cyclic_prerequisite = StudyRequest(
        fixture.power_flow.identity,
        fixture.power_flow.schema,
        fixture.power_flow.project_revision,
        fixture.power_flow.scenario,
        fixture.power_flow.representation,
        fixture.power_flow.fidelity,
        fixture.power_flow.method,
        collect(fixture.power_flow.settings),
        collect(fixture.power_flow.initialization),
        collect(fixture.power_flow.events),
        collect(fixture.power_flow.outputs),
        [StudyPrerequisite(
            ObjectIdentity(ProjectId("prerequisite.fault_result")),
            ProjectReference(ReferenceStudy, fixture.emt.identity.id),
            true,
            fixture.fault_contract.identity,
            fixture.provenance,
        )],
        fixture.power_flow.validity,
        fixture.provenance,
    )
    @test semantic_error_code(() -> validate_orchestration(project_with(
        studies = [cyclic_prerequisite, fixture.emt],
        results = ResultDeclaration[],
        workflows = WorkflowDefinition[],
    ))) == :study_prerequisite_cycle

    missing_automatic = WorkflowDefinition(
        ObjectIdentity(ProjectId("workflow.missing_automatic_prerequisite")),
        [WorkflowStep(
            ObjectIdentity(ProjectId("step.emt_without_power_flow")),
            ProjectReference(ReferenceStudy, fixture.emt.identity.id),
            ProjectId[],
            WorkflowInputBinding[],
            fixture.provenance,
        )],
        WorkflowStopOnFailure,
        WorkflowRecompute,
        fixture.provenance,
    )
    @test semantic_error_code(() -> validate_orchestration(project_with(
        workflows = [missing_automatic],
    ))) == :missing_automatic_prerequisite

    cyclic_first = WorkflowStep(
        fixture.power_flow_step.identity,
        fixture.power_flow_step.study,
        [fixture.emt_step.identity.id],
        WorkflowInputBinding[],
        fixture.provenance,
    )
    cyclic = WorkflowDefinition(
        fixture.workflow.identity,
        [cyclic_first, fixture.emt_step],
        fixture.workflow.failure,
        fixture.workflow.cache,
        fixture.provenance,
    )
    cyclic_project = unsafe_project(
        fixture.project.metadata,
        fixture.project.registry,
        fixture.project.units,
        collect(fixture.project.records),
        fixture.project.graphs,
        fixture.project.asset_library,
        fixture.project.hierarchy,
        fixture.project.control_system,
        fixture.project.event_scenarios,
        OrchestrationModel(
            study_schemas = collect(fixture.model.study_schemas),
            studies = collect(fixture.model.studies),
            result_contracts = collect(fixture.model.result_contracts),
            results = collect(fixture.model.results),
            workflows = [cyclic],
        ),
    )
    @test semantic_error_code(() -> validate_orchestration(cyclic_project)) == :workflow_cycle
end

@testset "experiment declarations enforce bounds ordering checkpoints and inert callbacks" begin
    fixture = ORCHESTRATION_FIXTURE
    @test semantic_error_code(() -> ExperimentExecution(
        ExperimentSerial,
        2,
        1,
        fixture.semantic_type("rng.stable"),
    )) == :serial_experiment_workers
    @test semantic_error_code(() -> ExperimentExecution(
        ExperimentParallelDeterministic,
        1,
        1,
        fixture.semantic_type("rng.stable"),
    )) == :parallel_experiment_workers
    @test semantic_error_code(() -> ExperimentStoppingCriteria(
        0,
        1,
        parse_exact_decimal("1.0e-8"),
        1,
        fixture.function_identity("converged", "3"),
        ExperimentTerminationError,
        ExperimentTerminationError,
    )) == :invalid_experiment_iteration_bound
    @test semantic_error_code(() -> DecisionVariable(
        ObjectIdentity(ProjectId("variable.unbounded")),
        ProjectReference(ReferenceAsset, ProjectId("bus.HV")),
        FieldPath("nameplate.rating"),
        UnitId("MVA"),
        OrientationScalar,
        DecisionContinuous,
        nothing,
        nothing,
        PhysicalValue{ScalarQuantity}[],
        fixture.provenance,
    ) |> variable -> AIMORAProject._validate_decision_variable(fixture.project, variable)) == :missing_decision_bounds
    @test semantic_error_code(() -> DecisionVariable(
        ObjectIdentity(ProjectId("variable.out_of_bounds")),
        ProjectReference(ReferenceAsset, ProjectId("bus.HV")),
        FieldPath("nameplate.rating"),
        UnitId("MVA"),
        OrientationScalar,
        DecisionContinuous,
        fixture.physical("80.0", "MVA"),
        fixture.physical("120.0", "MVA"),
        [fixture.physical("125.0", "MVA")],
        fixture.provenance,
    ) |> variable -> AIMORAProject._validate_decision_variable(fixture.project, variable)) == :decision_candidate_out_of_bounds
    @test semantic_error_code(() -> DecisionVariable(
        ObjectIdentity(ProjectId("variable.wrong_unit")),
        ProjectReference(ReferenceAsset, ProjectId("bus.HV")),
        FieldPath("nameplate.rating"),
        UnitId("MW"),
        OrientationScalar,
        DecisionContinuous,
        fixture.physical("80.0", "MW"),
        fixture.physical("120.0", "MW"),
        PhysicalValue{ScalarQuantity}[],
        fixture.provenance,
    ) |> variable -> AIMORAProject._validate_decision_variable(fixture.project, variable)) == :decision_variable_contract_mismatch
    @test semantic_error_code(() -> ExperimentCheckpoint(
        fixture.semantic_type("checkpoint.experiment"),
        0,
        1,
        true,
    )) == :invalid_experiment_checkpoint_interval
    for declaration in fixture.project.orchestration.experiments
        @test all(field_type -> field_type != Any, fieldtypes(typeof(declaration)))
        @test all(field_type -> !(field_type isa DataType && field_type <: Function), fieldtypes(typeof(declaration)))
        @test all(field_type -> !(field_type isa DataType && field_type <: AbstractDict), fieldtypes(typeof(declaration)))
    end
    @test !hasfield(RegisteredFunctionIdentity, :source)
    @test !hasfield(RegisteredFunctionIdentity, :callback)
    @test OrchestrationPatch <: ProjectPatch
    @test semantic_error_code(() -> AIMORAProject._scenario_patch_operation_valid(
        ScenarioPatchDeclaration(
            ObjectIdentity(ProjectId("patch.prohibited_workflow_mutation")),
            ScenarioAdd,
            AddWorkflowDefinitionPatch(fixture.workflow),
            1,
            fixture.provenance,
        ),
    )) == :scenario_operation_patch_mismatch
end

@testset "orchestration commands replay undo rollback and protect dependencies" begin
    fixture = ORCHESTRATION_FIXTURE
    additional_step = WorkflowStep(
        ObjectIdentity(ProjectId("step.power_flow_only")),
        fixture.power_flow_step.study,
        ProjectId[],
        WorkflowInputBinding[],
        fixture.provenance,
    )
    additional = WorkflowDefinition(
        ObjectIdentity(ProjectId("workflow.power_flow_only")),
        [additional_step],
        WorkflowStopOnFailure,
        WorkflowRecompute,
        fixture.provenance,
    )
    command = ProjectCommand(
        ProjectId("command.add_power_flow_workflow"),
        AddWorkflowDefinitionPatch(additional),
    )
    applied = replay_commands(fixture.project, [command])
    @test workflow_definition(applied.orchestration, additional.identity.id) == additional
    inverses = inverse_commands(fixture.project, [command])
    @test replay_commands(applied, inverses) == fixture.project
    @test semantic_error_code(() -> replay_commands(
        fixture.project,
        [ProjectCommand(
            ProjectId("command.remove_used_workflow"),
            RemoveWorkflowDefinitionPatch(fixture.workflow.identity.id),
        )],
    )) == :workflow_has_dependents

    base_revision = initial_revision(
        fixture.project,
        ContentDigest(repeat("c", 64)),
        ContentDigest(repeat("d", 64)),
        RevisionProvenance(
            ProjectId("action.orchestration_base"),
            DateTime(2026, 8, 9, 16, 0, 0),
            fixture.provenance,
        ),
    )
    transaction = begin_project_transaction(base_revision)
    apply!(transaction, command)
    @test rollback!(transaction) == base_revision
end

record_project_conformance!(:studies_workflows_experiments)

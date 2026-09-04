# SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
using Test
using AIMORAService

@testset "registered Julia inspection provider" begin
    mktempdir() do allowed_root
        project_path = joinpath(allowed_root, "inspection-project.json")
        write(project_path, "{\"project\":\"inspection\"}")
        configuration = AIMORAService.ServiceConfiguration(
            endpoint = joinpath(allowed_root, "service.sock"),
            session_token = repeat("a", 64),
            allowed_roots = [allowed_root],
        )
        state = AIMORAService.ServiceState(configuration)
        opened = AIMORAService.dispatch_request!(
            state,
            "request-open",
            "project.open",
            Dict{String,Any}("path" => project_path),
        )
        project_id = opened.result["project_id"]
        revision = Ref(7)
        description_count = Ref(0)
        commit_count = Ref(0)
        history_count = Ref(0)
        provider = InspectionProvider(
            describe = identity -> begin
                description_count[] += 1
                @test identity["project_id"] == project_id
                @test identity["asset_id"] == "asset.breaker.1"
                @test identity["asset_ids"] == ["asset.breaker.1", "asset.breaker.2"]
                Dict{String,Any}(
                    "schema_version" => "1.0.0",
                    "revision" => string(revision[]),
                    "identity" => identity,
                    "sections" => Any[
                        Dict{String,Any}(
                            "id" => "ratings",
                            "title" => "Ratings",
                            "available" => true,
                            "fields" => Any[
                                Dict{String,Any}(
                                    "path" => "ratings.voltage",
                                    "label" => "Rated voltage",
                                    "kind" => "number",
                                ),
                            ],
                        ),
                    ],
                    "values" => Dict{String,Any}(
                        "ratings.voltage" => Dict{String,Any}(
                            "value" => 11_000.0,
                            "canonical_unit" => "V",
                        ),
                    ),
                )
            end,
            commit = request -> begin
                commit_count[] += 1
                base_revision = parse(Int, request["base_revision"])
                if base_revision != revision[]
                    return Dict{String,Any}(
                        "status" => "conflict",
                        "revision" => string(revision[]),
                        "issues" => Any[],
                    )
                end
                revision[] += 1
                return Dict{String,Any}(
                    "status" => "accepted",
                    "revision" => string(revision[]),
                    "issues" => Any[],
                    "affected_model_paths" => Any["asset.breaker.1"],
                    "affected_view_ids" => Any["view.sld.1"],
                    "invalidated_result_ids" => Any["result.short-circuit.1"],
                )
            end,
            undo = request -> begin
                history_count[] += 1
                revision[] += 1
                Dict{String,Any}(
                    "status" => "accepted",
                    "revision" => string(revision[]),
                    "issues" => Any[],
                    "operation" => "undo",
                    "base_revision" => request["base_revision"],
                )
            end,
            redo = request -> begin
                history_count[] += 1
                revision[] += 1
                Dict{String,Any}(
                    "status" => "accepted",
                    "revision" => string(revision[]),
                    "issues" => Any[],
                    "operation" => "redo",
                    "base_revision" => request["base_revision"],
                )
            end,
        )
        @test register_inspection_provider!(state, project_id, provider) === provider

        identity = Dict{String,Any}(
            "project_id" => project_id,
            "asset_id" => "asset.breaker.1",
            "asset_ids" => Any["asset.breaker.1", "asset.breaker.2"],
            "projection_id" => "projection.breaker.1",
            "view_id" => "view.sld.1",
        )
        described = AIMORAService.dispatch_request!(
            state,
            "request-describe",
            "inspector.describe",
            identity,
        )
        @test described.result["schema_version"] == "1.0.0"
        @test described.result["revision"] == "7"
        @test description_count[] == 1

        commit_parameters = Dict{String,Any}(
            "project_id" => project_id,
            "asset_id" => "asset.breaker.1",
            "base_revision" => "7",
            "edits" => Any[
                Dict{String,Any}(
                    "path" => "ratings.voltage",
                    "value" => 13.8,
                    "display_unit" => "kV",
                ),
            ],
        )
        committed = AIMORAService.dispatch_request!(
            state,
            "request-commit",
            "inspector.commit",
            commit_parameters,
        )
        @test committed.result["status"] == "accepted"
        @test committed.result["revision"] == "8"
        @test commit_count[] == 1

        conflict = copy(commit_parameters)
        error = try
            AIMORAService.dispatch_request!(
                state,
                "request-conflict",
                "inspector.commit",
                conflict,
            )
            nothing
        catch exception
            exception
        end
        @test error isa AIMORAService.ServiceError
        @test error.code == "REVISION_CONFLICT"
        @test error.details["revision"] == "8"
        @test commit_count[] == 2

        undone = AIMORAService.dispatch_request!(
            state,
            "request-undo",
            "inspector.undo",
            Dict{String,Any}(
                "project_id" => project_id,
                "asset_id" => "asset.breaker.1",
                "base_revision" => "8",
            ),
        )
        @test undone.result["operation"] == "undo"
        redone = AIMORAService.dispatch_request!(
            state,
            "request-redo",
            "inspector.redo",
            Dict{String,Any}(
                "project_id" => project_id,
                "asset_id" => "asset.breaker.1",
                "base_revision" => "9",
            ),
        )
        @test redone.result["operation"] == "redo"
        @test history_count[] == 2

        closed = AIMORAService.dispatch_request!(
            state,
            "request-close",
            "project.close",
            Dict{String,Any}("project_id" => project_id),
        )
        @test closed.result["closed"]
        @test !haskey(state.inspection_providers, project_id)
    end
end

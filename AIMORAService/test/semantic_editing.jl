# SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
using Test
using AIMORAService

@testset "bounded Julia semantic edit transaction" begin
    mktempdir() do allowed_root
        project_path = joinpath(allowed_root, "semantic-project.json")
        write(project_path, "{\"project\":\"semantic\"}")
        configuration = AIMORAService.ServiceConfiguration(
            endpoint = joinpath(allowed_root, "service.sock"),
            session_token = repeat("b", 64),
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
        revision = Ref("sha256:base")
        received = Ref{Any}(nothing)
        provider = SemanticEditProvider(commit = request -> begin
            received[] = request
            if request["base_revision"] != revision[]
                return Dict{String,Any}(
                    "status" => "conflict",
                    "revision" => revision[],
                    "issues" => Any[],
                )
            end
            revision[] = "sha256:next"
            Dict{String,Any}(
                "status" => "accepted",
                "revision" => revision[],
                "changed_owner_ids" => request["semantic_ids"],
                "affected_view_ids" => Any["view.sld.1"],
                "invalidations" => Any["study_results", "workflow_results"],
                "issues" => Any[],
            )
        end)
        @test register_semantic_edit_provider!(state, project_id, provider) === provider

        parameters = Dict{String,Any}(
            "project_id" => project_id,
            "base_revision" => revision[],
            "transaction_id" => "studio-1",
            "operation" => "conductor.connect",
            "semantic_ids" => Any["port.source", "port.target"],
            "points" => Any[Any[10.0, 20.0], Any[30.0, 40.0]],
            "attributes" => Dict{String,Any}("view_id" => "view.sld.1"),
        )
        committed = AIMORAService.dispatch_request!(
            state,
            "request-semantic",
            "semantic.commit",
            parameters,
        )
        @test committed.result["status"] == "accepted"
        @test committed.result["revision"] == "sha256:next"
        @test received[]["semantic_ids"] == ["port.source", "port.target"]
        @test received[]["points"] == [[10.0, 20.0], [30.0, 40.0]]

        duplicate_ids = copy(parameters)
        duplicate_ids["base_revision"] = revision[]
        duplicate_ids["semantic_ids"] = Any["port.source", "port.source"]
        error = try
            AIMORAService.dispatch_request!(
                state,
                "request-duplicate",
                "semantic.commit",
                duplicate_ids,
            )
            nothing
        catch exception
            exception
        end
        @test error isa AIMORAService.ServiceError
        @test error.code == "INVALID_REQUEST"

        conflict = copy(parameters)
        conflict["base_revision"] = "sha256:stale"
        error = try
            AIMORAService.dispatch_request!(
                state,
                "request-conflict",
                "semantic.commit",
                conflict,
            )
            nothing
        catch exception
            exception
        end
        @test error isa AIMORAService.ServiceError
        @test error.code == "REVISION_CONFLICT"

        AIMORAService.dispatch_request!(
            state,
            "request-close",
            "project.close",
            Dict{String,Any}("project_id" => project_id),
        )
        @test !haskey(state.semantic_edit_providers, project_id)
    end
end

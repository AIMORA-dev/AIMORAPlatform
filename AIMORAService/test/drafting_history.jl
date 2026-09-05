# SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
module DraftingHistoryTests
using AIMORAProject
using AIMORAService
using Test

@testset "drafting history bounds retained command batches and discards abandoned redo" begin
    forward = ProjectCommand(ProjectId("action.rename.forward"), SetProjectNamePatch("After"))
    backward = ProjectCommand(ProjectId("action.rename.backward"), SetProjectNamePatch("Before"))
    entry = AIMORAService.DraftingHistoryEntry([forward], [backward])
    @test entry.retained_bytes > 0
    history = AIMORAService.DraftingHistory(maximum_entries = 2, maximum_bytes = 4 * entry.retained_bytes)
    for _ in 1:3
        @test AIMORAService._remember_drafting_edit!(history, entry)
    end
    @test length(history.undo) == 2
    @test history.retained_bytes == 2 * entry.retained_bytes
    push!(history.redo, pop!(history.undo))
    @test AIMORAService._remember_drafting_edit!(history, entry)
    @test isempty(history.redo)
    @test length(history.undo) == 2
    @test history.retained_bytes == 2 * entry.retained_bytes
    history.maximum_bytes = entry.retained_bytes
    @test AIMORAService._remember_drafting_edit!(history, entry)
    @test length(history.undo) == 1
    @test history.retained_bytes == entry.retained_bytes
    history.maximum_bytes = entry.retained_bytes - 1
    @test !AIMORAService._remember_drafting_edit!(history, entry)
    @test isempty(history.undo) && isempty(history.redo)
    @test history.retained_bytes == 0
    @test_throws ArgumentError AIMORAService.DraftingHistory(maximum_entries = 0)
    @test_throws ArgumentError AIMORAService.DraftingHistory(maximum_bytes = 0)
end
end

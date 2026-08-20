#!/usr/bin/env julia

root = @__DIR__
required = [
    "Project.toml",
    "README.md",
    joinpath("src", "AIMORAReporting.jl"),
    joinpath("src", "types.jl"),
    joinpath("src", "canonical.jl"),
    joinpath("src", "visuals.jl"),
    joinpath("src", "providers.jl"),
    joinpath("src", "qa.jl"),
    joinpath("src", "templates.jl"),
    joinpath("src", "renderers.jl"),
    joinpath("src", "workflow.jl"),
    joinpath("test", "runtests.jl"),
    joinpath("examples", "complete_report", "run.jl"),
]

missing = filter(path -> !isfile(joinpath(root, path)), required)
isempty(missing) || error("missing reporting package files: " * join(missing, ", "))

entrypoint = read(joinpath(root, "src", "AIMORAReporting.jl"), String)
for owner in ("types.jl", "canonical.jl", "visuals.jl", "providers.jl", "qa.jl", "templates.jl", "renderers.jl", "workflow.jl")
    occursin("include(\"$owner\")", entrypoint) || error("entrypoint does not include $owner")
end

for forbidden in ("AIMORASolvers", "private solver memory", "PyCall", "PythonCall", "MATLAB")
    for path in filter(path -> endswith(path, ".jl"), required)
        text = read(joinpath(root, path), String)
        occursin(forbidden, text) && error("reporting package contains forbidden dependency text '$forbidden' in $path")
    end
end

println("AIMORAReporting package structure: PASS")

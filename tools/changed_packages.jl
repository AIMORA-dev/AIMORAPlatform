module PlatformChangedPackages

using TOML

export affected_packages

function package_records(root::AbstractString)
    return TOML.parsefile(joinpath(root, "package-graph.toml"))["package"]
end

function affected_packages(root::AbstractString, changed_paths)
    packages = package_records(root)
    package_ids = sort!(String[package["id"] for package in packages])
    changed = Set{String}()
    unknown = false
    for raw_path in changed_paths
        path = replace(normpath(String(raw_path)), '\\' => '/')
        matched = false
        for package in packages
            prefix = String(package["path"]) * "/"
            if path == package["path"] || startswith(path, prefix)
                push!(changed, String(package["id"]))
                matched = true
            end
        end
        unknown |= !matched
    end
    unknown && union!(changed, package_ids)

    changed_in_iteration = true
    while changed_in_iteration
        changed_in_iteration = false
        for package in packages
            package_id = String(package["id"])
            package_id in changed && continue
            if any(dependency -> dependency in changed, String.(package["depends_on"]))
                push!(changed, package_id)
                changed_in_iteration = true
            end
        end
    end
    return sort!(collect(changed))
end

function changed_paths(root::AbstractString, base_revision::AbstractString, head_revision::AbstractString)
    command = `git -C $root diff --name-only $base_revision $head_revision`
    return split(read(command, String), '\n'; keepempty = false)
end

function json_array(values)
    return "[" * join(("\"$(value)\"" for value in values), ",") * "]"
end

function main(arguments)
    json_output = !isempty(arguments) && first(arguments) == "--json"
    json_output && (arguments = arguments[2:end])
    length(arguments) == 2 || error("usage: changed_packages.jl [--json] <base-revision> <head-revision>")
    root = normpath(joinpath(@__DIR__, ".."))
    packages = affected_packages(root, changed_paths(root, arguments[1], arguments[2]))
    if json_output
        println(json_array(packages))
    else
        foreach(println, packages)
    end
end

end

if abspath(PROGRAM_FILE) == @__FILE__
    PlatformChangedPackages.main(ARGS)
end

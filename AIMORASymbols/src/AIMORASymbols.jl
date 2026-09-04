module AIMORASymbols

using SHA
using TOML

export ExactCoordinate, SymbolPoint, SymbolBounds, LocalTransform,
       AbstractSymbolPrimitive, LinePrimitive, PolylinePrimitive, ArcPrimitive,
       CirclePrimitive, EllipsePrimitive, PolygonPrimitive, SymbolPort,
       SymbolAnchor, SymbolStyle, SymbolVariant, SymbolDefinition, SymbolLibrary,
       AbstractCompileTarget, RetainedSceneTarget, ReferenceGeometryTarget,
       PdfVectorTarget, DxfBlockTarget, CompiledSymbol, load_symbol, load_library,
       select_variant, compile_symbol, geometry_signature, content_hash, source_hash

const FORMAT_VERSION = "1.0"
const REQUIRED_LICENSE = "PolyForm-Noncommercial-1.0.0"
const REQUIRED_PROVENANCE = "AIMORA original"
const IDENTIFIER = r"^[a-z][a-z0-9_]*(?:\.[a-z][a-z0-9_]*)*$"

struct ExactCoordinate
    value::Rational{BigInt}
end
ExactCoordinate(value::Integer) = ExactCoordinate(BigInt(value) // BigInt(1))
function ExactCoordinate(text::AbstractString)
    token = strip(text)
    occursin(r"^[+-]?\d+(?:\.\d+)?$", token) || throw(ArgumentError("coordinate must be an integer or decimal string"))
    negative = startswith(token, "-")
    unsigned = replace(token, r"^[+-]" => "")
    parts = split(unsigned, '.'; limit = 2)
    denominator_value = length(parts) == 2 ? BigInt(10)^length(parts[2]) : BigInt(1)
    numerator_value = parse(BigInt, parts[1]) * denominator_value
    length(parts) == 2 && (numerator_value += parse(BigInt, parts[2]))
    negative && (numerator_value = -numerator_value)
    return ExactCoordinate(numerator_value // denominator_value)
end
Base.:(==)(a::ExactCoordinate, b::ExactCoordinate) = a.value == b.value
Base.isless(a::ExactCoordinate, b::ExactCoordinate) = isless(a.value, b.value)
Base.hash(value::ExactCoordinate, seed::UInt) = hash(value.value, seed)

struct SymbolPoint
    x::ExactCoordinate
    y::ExactCoordinate
end
struct SymbolBounds
    minimum::SymbolPoint
    maximum::SymbolPoint
    function SymbolBounds(minimum, maximum)
        minimum.x < maximum.x || throw(ArgumentError("bounds require min x < max x"))
        minimum.y < maximum.y || throw(ArgumentError("bounds require min y < max y"))
        new(minimum, maximum)
    end
end
struct LocalTransform
    translation::SymbolPoint
    rotation_degrees::Int
    scale_x::ExactCoordinate
    scale_y::ExactCoordinate
end

abstract type AbstractSymbolPrimitive end
struct LinePrimitive <: AbstractSymbolPrimitive
    first::SymbolPoint; last::SymbolPoint; style::String
end
struct PolylinePrimitive <: AbstractSymbolPrimitive
    points::Vector{SymbolPoint}; style::String
end
struct ArcPrimitive <: AbstractSymbolPrimitive
    center::SymbolPoint; radius::ExactCoordinate; start_degrees::Int; sweep_degrees::Int; style::String
end
struct CirclePrimitive <: AbstractSymbolPrimitive
    center::SymbolPoint; radius::ExactCoordinate; style::String
end
struct EllipsePrimitive <: AbstractSymbolPrimitive
    center::SymbolPoint; radius_x::ExactCoordinate; radius_y::ExactCoordinate; style::String
end
struct PolygonPrimitive <: AbstractSymbolPrimitive
    points::Vector{SymbolPoint}; style::String
end

struct SymbolPort
    id::String; role::String; position::SymbolPoint; direction_degrees::Int
end
struct SymbolAnchor
    id::String; role::String; position::SymbolPoint
end
struct SymbolStyle
    id::String; stroke::String; stroke_width::ExactCoordinate; fill::String; text_role::String
end
struct SymbolVariant
    state::String
    level_of_detail::String
    primitives::Vector{AbstractSymbolPrimitive}
    clip::Union{Nothing,SymbolBounds}
    transform::LocalTransform
end
struct SymbolDefinition
    id::String
    name::String
    asset_class::String
    units::String
    bounds::SymbolBounds
    rotations::Vector{Int}
    accessibility::String
    provenance::String
    license::String
    styles::Dict{String,SymbolStyle}
    ports::Vector{SymbolPort}
    anchors::Vector{SymbolAnchor}
    variants::Dict{Tuple{String,String},SymbolVariant}
    default_state::String
    canonical_hash::String
end
struct SymbolLibrary
    id::String; version::String; symbols::Dict{String,SymbolDefinition}
end

abstract type AbstractCompileTarget end
struct RetainedSceneTarget <: AbstractCompileTarget end
struct ReferenceGeometryTarget <: AbstractCompileTarget end
struct PdfVectorTarget <: AbstractCompileTarget end
struct DxfBlockTarget <: AbstractCompileTarget end
struct CompiledSymbol
    symbol_id::String
    target::Symbol
    state::String
    level_of_detail::String
    commands::Vector{NamedTuple}
    signature::String
end

coordinate(value) = value isa Integer || value isa AbstractString ? ExactCoordinate(value) : throw(ArgumentError("coordinates cannot use binary floating point"))
function point(value)
    value isa AbstractVector && length(value) == 2 || throw(ArgumentError("point requires two coordinates"))
    return SymbolPoint(coordinate(value[1]), coordinate(value[2]))
end
function bounds(value)
    value isa AbstractVector && length(value) == 4 || throw(ArgumentError("bounds require four coordinates"))
    return SymbolBounds(point(value[1:2]), point(value[3:4]))
end
function require_keys(table, required, allowed, context)
    names = Set(String.(keys(table)))
    missing = setdiff(Set(required), names)
    extra = setdiff(names, Set(allowed))
    isempty(missing) || throw(ArgumentError("$context missing keys: $(join(sort!(collect(missing)), ", "))"))
    isempty(extra) || throw(ArgumentError("$context has unsupported keys: $(join(sort!(collect(extra)), ", "))"))
end
function checked_id(value, context)
    id = String(value)
    occursin(IDENTIFIER, id) || throw(ArgumentError("$context has invalid identifier '$id'"))
    return id
end
function parse_style(id, table)
    fields = ["stroke", "stroke_width", "fill", "text_role"]
    require_keys(table, fields, fields, "style $id")
    width = coordinate(table["stroke_width"])
    width.value > 0 || throw(ArgumentError("stroke width must be positive"))
    return SymbolStyle(id, String(table["stroke"]), width, String(table["fill"]), String(table["text_role"]))
end
function parse_primitive(table, styles)
    kind, style = String(get(table, "type", "")), String(get(table, "style", ""))
    haskey(styles, style) || throw(ArgumentError("primitive references unknown style '$style'"))
    if kind == "line"
        require_keys(table, ["type", "from", "to", "style"], ["type", "from", "to", "style"], "line")
        return LinePrimitive(point(table["from"]), point(table["to"]), style)
    elseif kind == "polyline"
        require_keys(table, ["type", "points", "style"], ["type", "points", "style"], "polyline")
        points = SymbolPoint[point(item) for item in table["points"]]
        length(points) >= 2 || throw(ArgumentError("polyline requires two points"))
        return PolylinePrimitive(points, style)
    elseif kind == "arc"
        require_keys(table, ["type", "center", "radius", "start", "sweep", "style"], ["type", "center", "radius", "start", "sweep", "style"], "arc")
        radius, sweep = coordinate(table["radius"]), Int(table["sweep"])
        radius.value > 0 && 0 < abs(sweep) <= 360 || throw(ArgumentError("invalid arc geometry"))
        return ArcPrimitive(point(table["center"]), radius, Int(table["start"]), sweep, style)
    elseif kind == "circle"
        require_keys(table, ["type", "center", "radius", "style"], ["type", "center", "radius", "style"], "circle")
        radius = coordinate(table["radius"]); radius.value > 0 || throw(ArgumentError("invalid circle radius"))
        return CirclePrimitive(point(table["center"]), radius, style)
    elseif kind == "ellipse"
        require_keys(table, ["type", "center", "radius_x", "radius_y", "style"], ["type", "center", "radius_x", "radius_y", "style"], "ellipse")
        radius_x, radius_y = coordinate(table["radius_x"]), coordinate(table["radius_y"])
        radius_x.value > 0 && radius_y.value > 0 || throw(ArgumentError("invalid ellipse radii"))
        return EllipsePrimitive(point(table["center"]), radius_x, radius_y, style)
    elseif kind == "polygon"
        require_keys(table, ["type", "points", "style"], ["type", "points", "style"], "polygon")
        points = SymbolPoint[point(item) for item in table["points"]]
        length(points) >= 3 || throw(ArgumentError("polygon requires three points"))
        return PolygonPrimitive(points, style)
    end
    throw(ArgumentError("unsupported primitive '$kind'"))
end
function parse_transform(table)
    table === nothing && return LocalTransform(point([0, 0]), 0, coordinate(1), coordinate(1))
    require_keys(table, String[], ["translate", "rotate", "scale"], "transform")
    scale = get(table, "scale", [1, 1])
    scale isa AbstractVector && length(scale) == 2 || throw(ArgumentError("scale requires two values"))
    scale_x, scale_y = coordinate(scale[1]), coordinate(scale[2])
    scale_x.value != 0 && scale_y.value != 0 || throw(ArgumentError("scale cannot be zero"))
    return LocalTransform(point(get(table, "translate", [0, 0])), Int(get(table, "rotate", 0)), scale_x, scale_y)
end
inside(value, area) = !(value.x < area.minimum.x) && !(area.maximum.x < value.x) && !(value.y < area.minimum.y) && !(area.maximum.y < value.y)
primitive_points(value::LinePrimitive) = [value.first, value.last]
primitive_points(value::Union{PolylinePrimitive,PolygonPrimitive}) = value.points
primitive_points(value::Union{ArcPrimitive,CirclePrimitive,EllipsePrimitive}) = [value.center]
function validate_bounds(value, area)
    all(item -> inside(item, area), primitive_points(value)) || throw(ArgumentError("primitive point outside bounds"))
    if value isa Union{ArcPrimitive,CirclePrimitive}
        radius = value.radius.value
        inside(SymbolPoint(ExactCoordinate(value.center.x.value - radius), ExactCoordinate(value.center.y.value - radius)), area) || throw(ArgumentError("radial primitive outside bounds"))
        inside(SymbolPoint(ExactCoordinate(value.center.x.value + radius), ExactCoordinate(value.center.y.value + radius)), area) || throw(ArgumentError("radial primitive outside bounds"))
    elseif value isa EllipsePrimitive
        inside(SymbolPoint(ExactCoordinate(value.center.x.value - value.radius_x.value), ExactCoordinate(value.center.y.value - value.radius_y.value)), area) || throw(ArgumentError("ellipse outside bounds"))
        inside(SymbolPoint(ExactCoordinate(value.center.x.value + value.radius_x.value), ExactCoordinate(value.center.y.value + value.radius_y.value)), area) || throw(ArgumentError("ellipse outside bounds"))
    end
end
function canonical(value)
    value isa AbstractDict && return "{" * join((repr(String(key)) * ":" * canonical(value[key]) for key in sort!(collect(keys(value)); by = String)), ",") * "}"
    value isa AbstractVector && return "[" * join(canonical.(value), ",") * "]"
    value isa AbstractString && return repr(String(value))
    value isa Integer || value isa Bool || throw(ArgumentError("unsupported canonical value $(typeof(value))"))
    return string(value)
end
content_hash(table) = bytes2hex(sha256(codeunits(canonical(table))))
source_hash(path) = bytes2hex(sha256(read(path)))

function load_symbol(path)
    filesize(path) <= 256_000 || throw(ArgumentError("symbol source exceeds size limit"))
    table = TOML.parsefile(path)
    required = ["format_version", "id", "name", "asset_class", "units", "bounds", "rotations", "accessibility", "provenance", "license", "default_state", "styles", "ports", "anchors", "states"]
    require_keys(table, required, required, "symbol")
    table["format_version"] == FORMAT_VERSION || throw(ArgumentError("unsupported format version"))
    table["provenance"] == REQUIRED_PROVENANCE || throw(ArgumentError("symbol must be AIMORA original artwork"))
    table["license"] == REQUIRED_LICENSE || throw(ArgumentError("symbol must use PolyForm-Noncommercial-1.0.0"))
    id, area = checked_id(table["id"], "symbol"), bounds(table["bounds"])
    rotations = sort!(unique!(Int.(table["rotations"])))
    !isempty(rotations) && all(value -> 0 <= value < 360 && value % 90 == 0, rotations) || throw(ArgumentError("rotations must be quarter turns"))
    styles = Dict{String,SymbolStyle}(String(key) => parse_style(String(key), value) for (key, value) in table["styles"])
    isempty(styles) && throw(ArgumentError("symbol requires styles"))
    ports = SymbolPort[]
    for item in table["ports"]
        require_keys(item, ["id", "role", "position", "direction"], ["id", "role", "position", "direction"], "port")
        position = point(item["position"]); inside(position, area) || throw(ArgumentError("port outside bounds"))
        push!(ports, SymbolPort(checked_id(item["id"], "port"), String(item["role"]), position, Int(item["direction"])))
    end
    !isempty(ports) && length(unique(port.id for port in ports)) == length(ports) || throw(ArgumentError("symbol requires unique ports"))
    anchors = SymbolAnchor[]
    for item in table["anchors"]
        require_keys(item, ["id", "role", "position"], ["id", "role", "position"], "anchor")
        position = point(item["position"]); inside(position, area) || throw(ArgumentError("anchor outside bounds"))
        push!(anchors, SymbolAnchor(checked_id(item["id"], "anchor"), String(item["role"]), position))
    end
    length(unique(anchor.id for anchor in anchors)) == length(anchors) || throw(ArgumentError("anchor ids must be unique"))
    variants = Dict{Tuple{String,String},SymbolVariant}()
    for (state, levels) in table["states"], (level, variant_table) in levels
        require_keys(variant_table, ["primitives"], ["primitives", "clip", "transform"], "variant")
        primitives = AbstractSymbolPrimitive[parse_primitive(item, styles) for item in variant_table["primitives"]]
        0 < length(primitives) <= 128 || throw(ArgumentError("invalid primitive count"))
        foreach(value -> validate_bounds(value, area), primitives)
        variants[(checked_id(state, "state"), checked_id(level, "level"))] = SymbolVariant(state, level, primitives,
            haskey(variant_table, "clip") ? bounds(variant_table["clip"]) : nothing, parse_transform(get(variant_table, "transform", nothing)))
    end
    default_state = String(table["default_state"])
    any(first(key) == default_state for key in keys(variants)) || throw(ArgumentError("default state has no variant"))
    return SymbolDefinition(id, String(table["name"]), String(table["asset_class"]), String(table["units"]), area, rotations,
        String(table["accessibility"]), String(table["provenance"]), String(table["license"]), styles, ports, anchors,
        variants, default_state, content_hash(table))
end

function load_library(root)
    metadata = TOML.parsefile(joinpath(root, "metadata", "library.toml"))
    fields = ["format_version", "library_id", "version", "licence", "symbols"]
    require_keys(metadata, fields, fields, "library")
    metadata["format_version"] == FORMAT_VERSION && metadata["licence"] == REQUIRED_LICENSE || throw(ArgumentError("invalid library contract"))
    symbols = Dict{String,SymbolDefinition}()
    for record in metadata["symbols"]
        record_fields = ["id", "path", "source_sha256", "content_sha256"]
        require_keys(record, record_fields, record_fields, "symbol record")
        relative = String(record["path"])
        !isabspath(relative) && !startswith(normpath(relative), "..") || throw(ArgumentError("symbol path escapes root"))
        path = joinpath(root, normpath(relative)); isfile(path) || throw(ArgumentError("missing symbol source"))
        source_hash(path) == lowercase(String(record["source_sha256"])) || throw(ArgumentError("source hash mismatch"))
        symbol = load_symbol(path)
        symbol.id == record["id"] && symbol.canonical_hash == lowercase(String(record["content_sha256"])) || throw(ArgumentError("symbol record mismatch"))
        haskey(symbols, symbol.id) && throw(ArgumentError("duplicate symbol id"))
        symbols[symbol.id] = symbol
    end
    isempty(symbols) && throw(ArgumentError("library cannot be empty"))
    return SymbolLibrary(String(metadata["library_id"]), String(metadata["version"]), symbols)
end

function select_variant(symbol; state = symbol.default_state, level_of_detail = "detail")
    for key in ((String(state), String(level_of_detail)), (String(state), "detail"), (symbol.default_state, String(level_of_detail)), (symbol.default_state, "detail"))
        haskey(symbol.variants, key) && return symbol.variants[key]
    end
    throw(ArgumentError("symbol has no fallback variant"))
end
exact_text(value) = denominator(value.value) == 1 ? string(numerator(value.value)) : "$(numerator(value.value))/$(denominator(value.value))"
point_command(value) = (x = exact_text(value.x), y = exact_text(value.y))
primitive_command(value::LinePrimitive) = (kind=:line, points=[point_command(value.first), point_command(value.last)], radii=String[], angles=Int[], style=value.style)
primitive_command(value::PolylinePrimitive) = (kind=:polyline, points=point_command.(value.points), radii=String[], angles=Int[], style=value.style)
primitive_command(value::PolygonPrimitive) = (kind=:polygon, points=point_command.(value.points), radii=String[], angles=Int[], style=value.style)
primitive_command(value::ArcPrimitive) = (kind=:arc, points=[point_command(value.center)], radii=[exact_text(value.radius)], angles=[value.start_degrees, value.sweep_degrees], style=value.style)
primitive_command(value::CirclePrimitive) = (kind=:circle, points=[point_command(value.center)], radii=[exact_text(value.radius)], angles=Int[], style=value.style)
primitive_command(value::EllipsePrimitive) = (kind=:ellipse, points=[point_command(value.center)], radii=[exact_text(value.radius_x), exact_text(value.radius_y)], angles=Int[], style=value.style)
target_name(::RetainedSceneTarget) = :retained_scene
target_name(::ReferenceGeometryTarget) = :reference_geometry
target_name(::PdfVectorTarget) = :pdf_vector
target_name(::DxfBlockTarget) = :dxf_block
function geometry_signature(commands)
    rows = [Dict("kind" => String(item.kind), "points" => [Dict("x" => p.x, "y" => p.y) for p in item.points], "radii" => item.radii, "angles" => item.angles, "style" => item.style) for item in commands]
    return bytes2hex(sha256(codeunits(canonical(rows))))
end
geometry_signature(compiled::CompiledSymbol) = compiled.signature
function compile_symbol(symbol, target; state = symbol.default_state, level_of_detail = "detail")
    variant = select_variant(symbol; state, level_of_detail)
    commands = NamedTuple[primitive_command(item) for item in variant.primitives]
    return CompiledSymbol(symbol.id, target_name(target), variant.state, variant.level_of_detail, commands, geometry_signature(commands))
end

end

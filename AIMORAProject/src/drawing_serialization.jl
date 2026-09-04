export DrawingSymbolBinding,
    DrawingWorkspaceDocument,
    DrawingWorkspaceReadResult,
    drawing_workspace_sha256,
    parse_drawing_workspace,
    serialize_drawing_workspace

struct DrawingSymbolBinding
    owner::ProjectId
    symbol_id::String
    library_id::String
    content_sha256::String
    state::String
    level_of_detail::String

    function DrawingSymbolBinding(
        owner::ProjectId,
        symbol_id::AbstractString,
        library_id::AbstractString,
        content_sha256::AbstractString;
        state::AbstractString = "normal",
        level_of_detail::AbstractString = "detail",
    )
        reference = AIMORAFormats.NativeSymbolReference(
            owner.value,
            symbol_id,
            library_id,
            content_sha256;
            state,
            level_of_detail,
        )
        return new(
            owner,
            reference.symbol_id,
            reference.library_id,
            reference.content_sha256,
            reference.state,
            reference.level_of_detail,
        )
    end
end

Base.:(==)(left::DrawingSymbolBinding, right::DrawingSymbolBinding) =
    left.owner == right.owner &&
    left.symbol_id == right.symbol_id &&
    left.library_id == right.library_id &&
    left.content_sha256 == right.content_sha256 &&
    left.state == right.state &&
    left.level_of_detail == right.level_of_detail

struct DrawingWorkspaceDocument
    project_id::ProjectId
    workspace::DrawingWorkspace
    symbols::AIMORAFormats.FormatItemList{DrawingSymbolBinding}
    migration::AIMORAFormats.NativeDrawingMigrationReport
    missing_cache_paths::AIMORAFormats.FormatItemList{String}

    function DrawingWorkspaceDocument(
        project_id::ProjectId,
        workspace::DrawingWorkspace,
        symbols::AbstractVector{DrawingSymbolBinding},
        migration::AIMORAFormats.NativeDrawingMigrationReport,
        missing_cache_paths::AbstractVector{<:AbstractString},
    )
        ordered = sort!(collect(symbols); by = item -> item.owner.value)
        owners = getfield.(ordered, :owner)
        length(owners) == length(unique(owners)) ||
            throw(ArgumentError("drawing symbol owners must be unique"))
        drawing_ids = _drawing_workspace_ids(workspace)
        all(binding -> binding.owner in drawing_ids, ordered) ||
            throw(ArgumentError("drawing symbol binding owner is absent from the workspace"))
        return new(
            project_id,
            workspace,
            AIMORAFormats.FormatItemList(ordered),
            migration,
            AIMORAFormats.FormatItemList(sort!(String.(missing_cache_paths))),
        )
    end
end

const DrawingWorkspaceReadResult = AIMORAFormats.FormatResult{DrawingWorkspaceDocument}

_drawing_id(value::ProjectId) = value.value
_drawing_optional_id(value::Union{Nothing,ProjectId}) = isnothing(value) ? nothing : value.value
_drawing_global_id(value::Union{Nothing,GlobalId}) = isnothing(value) ? nothing : value.uri
_drawing_list_ids(values) = [_drawing_id(value) for value in values]

_drawing_exact(value::ExactDecimal) = Dict(
    "coefficient" => string(value.coefficient),
    "exponent" => value.exponent,
    "negative_zero" => value.negative_zero,
)

_drawing_coordinate(value::DrawingCoordinate) = Dict(
    "x" => _drawing_exact(value.x),
    "y" => _drawing_exact(value.y),
)

_drawing_identity(value::ObjectIdentity) = Dict(
    "id" => _drawing_id(value.id),
    "uid" => _drawing_global_id(value.uid),
)

_drawing_licence(value::LicenceIdentity) = Dict(
    "id" => value.id,
    "name" => value.name,
    "uri" => _drawing_global_id(value.uri),
)

_drawing_provenance(value::ProvenanceSource) = Dict(
    "id" => _drawing_id(value.id),
    "citation" => value.citation,
    "source_uri" => _drawing_global_id(value.source_uri),
    "source_sha256" => value.source_sha256,
    "source_version" => value.source_version,
    "licence" => _drawing_licence(value.licence),
)

function _drawing_space(value::DrawingSpace)
    value == DrawingModelSpace && return "model"
    value == DrawingPaperSpace && return "paper"
    throw(ArgumentError("unsupported drawing space"))
end

function _drawing_style_kind(value::DrawingStyleKind)
    value == DrawingLineStyle && return "line"
    value == DrawingTextStyle && return "text"
    value == DrawingDimensionStyle && return "dimension"
    value == DrawingPlotStyle && return "plot"
    throw(ArgumentError("unsupported drawing style kind"))
end

function _drawing_lock_aspect(value::DrawingLockAspect)
    value == DrawingPositionLock && return "position"
    value == DrawingGeometryLock && return "geometry"
    value == DrawingContentLock && return "content"
    value == DrawingVisibilityLock && return "visibility"
    throw(ArgumentError("unsupported drawing lock aspect"))
end

_drawing_style_value(value::Bool) = Dict("kind" => "boolean", "value" => value)
_drawing_style_value(value::String) = Dict("kind" => "string", "value" => value)
_drawing_style_value(value::ProjectId) = Dict("kind" => "id", "value" => value.value)
_drawing_style_value(value::ExactDecimal) = Dict("kind" => "decimal", "value" => _drawing_exact(value))

function _drawing_workspace_data(workspace::DrawingWorkspace)
    documents = [Dict(
        "identity" => _drawing_identity(item.identity),
        "name" => item.name,
        "views" => _drawing_list_ids(item.views),
        "sheets" => _drawing_list_ids(item.sheets),
        "provenance" => _drawing_provenance(item.provenance),
    ) for item in workspace.documents]
    views = [Dict(
        "identity" => _drawing_identity(item.identity),
        "document" => _drawing_id(item.document),
        "name" => item.name,
        "space" => _drawing_space(item.space),
        "semantic_view" => _drawing_optional_id(item.semantic_view),
        "provenance" => _drawing_provenance(item.provenance),
    ) for item in workspace.views]
    sheets = [Dict(
        "identity" => _drawing_identity(item.identity),
        "document" => _drawing_id(item.document),
        "view" => _drawing_id(item.view),
        "name" => item.name,
        "width" => _drawing_exact(item.width),
        "height" => _drawing_exact(item.height),
        "provenance" => _drawing_provenance(item.provenance),
    ) for item in workspace.sheets]
    viewports = [Dict(
        "identity" => _drawing_identity(item.identity),
        "sheet" => _drawing_id(item.sheet),
        "view" => _drawing_id(item.view),
        "origin" => _drawing_coordinate(item.origin),
        "width" => _drawing_exact(item.width),
        "height" => _drawing_exact(item.height),
        "scale" => _drawing_exact(item.scale),
        "rotation_degrees" => _drawing_exact(item.rotation_degrees),
        "visible_layers" => _drawing_list_ids(item.visible_layers),
        "provenance" => _drawing_provenance(item.provenance),
    ) for item in workspace.viewports]
    layers = [Dict(
        "identity" => _drawing_identity(item.identity),
        "document" => _drawing_id(item.document),
        "name" => item.name,
        "visible" => item.visible,
        "printable" => item.printable,
        "provenance" => _drawing_provenance(item.provenance),
    ) for item in workspace.layers]
    styles = [Dict(
        "identity" => _drawing_identity(item.identity),
        "document" => _drawing_id(item.document),
        "name" => item.name,
        "kind" => _drawing_style_kind(item.kind),
        "properties" => [Dict("name" => property.name.value, "value" => _drawing_style_value(property.value)) for property in item.properties],
        "provenance" => _drawing_provenance(item.provenance),
    ) for item in workspace.styles]
    blocks = [Dict(
        "identity" => _drawing_identity(item.identity),
        "document" => _drawing_id(item.document),
        "name" => item.name,
        "base_point" => _drawing_coordinate(item.base_point),
        "provenance" => _drawing_provenance(item.provenance),
    ) for item in workspace.blocks]
    entities = [Dict(
        "identity" => _drawing_identity(item.identity),
        "container" => _drawing_id(item.container),
        "layer" => _drawing_id(item.layer),
        "kind" => _drawing_id(item.kind),
        "points" => [_drawing_coordinate(point) for point in item.points],
        "style" => _drawing_optional_id(item.style),
        "block_definition" => _drawing_optional_id(item.block_definition),
        "provenance" => _drawing_provenance(item.provenance),
    ) for item in workspace.entities]
    projections = [Dict(
        "identity" => _drawing_identity(item.identity),
        "view" => _drawing_id(item.view),
        "semantic_projection" => _drawing_id(item.semantic_projection),
        "layer" => _drawing_id(item.layer),
        "position" => _drawing_coordinate(item.position),
        "rotation_degrees" => _drawing_exact(item.rotation_degrees),
        "scale" => _drawing_exact(item.scale),
        "provenance" => _drawing_provenance(item.provenance),
    ) for item in workspace.projections]
    routes = [Dict(
        "identity" => _drawing_identity(item.identity),
        "view" => _drawing_id(item.view),
        "layer" => _drawing_id(item.layer),
        "semantic_connection" => _drawing_optional_id(item.semantic_connection),
        "points" => [_drawing_coordinate(point) for point in item.points],
        "style" => _drawing_optional_id(item.style),
        "provenance" => _drawing_provenance(item.provenance),
    ) for item in workspace.routes]
    labels = [Dict(
        "identity" => _drawing_identity(item.identity),
        "view" => _drawing_id(item.view),
        "layer" => _drawing_id(item.layer),
        "anchor" => _drawing_coordinate(item.anchor),
        "text" => item.text,
        "style" => _drawing_optional_id(item.style),
        "bound_owner" => _drawing_optional_id(item.bound_owner),
        "bound_field" => item.bound_field,
        "provenance" => _drawing_provenance(item.provenance),
    ) for item in workspace.labels]
    locks = [Dict(
        "identity" => _drawing_identity(item.identity),
        "owner" => _drawing_id(item.owner),
        "aspects" => [_drawing_lock_aspect(aspect) for aspect in item.aspects],
        "reason" => item.reason,
        "provenance" => _drawing_provenance(item.provenance),
    ) for item in workspace.locks]
    return Dict(
        "documents" => documents,
        "views" => views,
        "sheets" => sheets,
        "viewports" => viewports,
        "layers" => layers,
        "styles" => styles,
        "blocks" => blocks,
        "entities" => entities,
        "projections" => projections,
        "routes" => routes,
        "labels" => labels,
        "locks" => locks,
    )
end

function _drawing_workspace_ids(workspace::DrawingWorkspace)
    ids = Set{ProjectId}()
    for collection in (
        workspace.documents, workspace.views, workspace.sheets, workspace.viewports,
        workspace.layers, workspace.styles, workspace.blocks, workspace.entities,
        workspace.projections, workspace.routes, workspace.labels, workspace.locks,
    )
        union!(ids, (item.identity.id for item in collection))
    end
    return ids
end

function _validate_drawing_symbol_bindings(
    workspace::DrawingWorkspace,
    symbols::AbstractVector{DrawingSymbolBinding},
)
    owners = getfield.(symbols, :owner)
    length(owners) == length(unique(owners)) ||
        throw(ArgumentError("drawing symbol owners must be unique"))
    drawing_ids = _drawing_workspace_ids(workspace)
    all(owner -> owner in drawing_ids, owners) ||
        throw(ArgumentError("drawing symbol binding owner is absent from the workspace"))
    return symbols
end

function _drawing_map(value, fields, role)
    value isa AbstractDict || throw(ArgumentError("$(role) must be an object"))
    names = Set(String.(keys(value)))
    expected = Set(fields)
    names == expected || throw(ArgumentError("$(role) fields do not match the native schema"))
    return value
end

function _drawing_array(value, role)
    value isa AbstractVector || throw(ArgumentError("$(role) must be an array"))
    return value
end

function _drawing_string(value, role)
    value isa AbstractString || throw(ArgumentError("$(role) must be a string"))
    return String(value)
end

function _drawing_bool(value, role)
    value isa Bool || throw(ArgumentError("$(role) must be a boolean"))
    return value
end

function _drawing_int(value, role)
    value isa Integer || throw(ArgumentError("$(role) must be an integer"))
    typemin(Int) <= value <= typemax(Int) || throw(ArgumentError("$(role) exceeds Int"))
    return Int(value)
end

function _drawing_optional(value, parser)
    return isnothing(value) ? nothing : parser(value)
end

function _parse_drawing_exact(value)
    table = _drawing_map(value, ["coefficient", "exponent", "negative_zero"], "exact decimal")
    coefficient = try
        parse(BigInt, _drawing_string(table["coefficient"], "decimal coefficient"))
    catch
        throw(ArgumentError("decimal coefficient is invalid"))
    end
    return ExactDecimal(
        coefficient,
        _drawing_int(table["exponent"], "decimal exponent");
        negative_zero = _drawing_bool(table["negative_zero"], "negative zero"),
    )
end

function _parse_drawing_coordinate(value)
    table = _drawing_map(value, ["x", "y"], "drawing coordinate")
    return DrawingCoordinate(_parse_drawing_exact(table["x"]), _parse_drawing_exact(table["y"]))
end

function _parse_drawing_identity(value)
    table = _drawing_map(value, ["id", "uid"], "object identity")
    uid = _drawing_optional(table["uid"], value -> GlobalId(_drawing_string(value, "global id")))
    return ObjectIdentity(ProjectId(_drawing_string(table["id"], "project id")); uid)
end

function _parse_drawing_licence(value)
    table = _drawing_map(value, ["id", "name", "uri"], "licence")
    uri = _drawing_optional(table["uri"], value -> GlobalId(_drawing_string(value, "licence URI")))
    return LicenceIdentity(
        _drawing_string(table["id"], "licence id"),
        _drawing_string(table["name"], "licence name");
        uri,
    )
end

function _parse_drawing_provenance(value)
    fields = ["id", "citation", "source_uri", "source_sha256", "source_version", "licence"]
    table = _drawing_map(value, fields, "provenance")
    source_uri = _drawing_optional(table["source_uri"], value -> GlobalId(_drawing_string(value, "source URI")))
    source_sha256 = _drawing_optional(table["source_sha256"], value -> _drawing_string(value, "source hash"))
    source_version = _drawing_optional(table["source_version"], value -> _drawing_string(value, "source version"))
    return ProvenanceSource(
        ProjectId(_drawing_string(table["id"], "provenance id")),
        _drawing_string(table["citation"], "citation"),
        _parse_drawing_licence(table["licence"]);
        source_uri,
        source_sha256,
        source_version,
    )
end

function _parse_drawing_style_value(value)
    table = _drawing_map(value, ["kind", "value"], "style value")
    kind = _drawing_string(table["kind"], "style value kind")
    kind == "boolean" && return _drawing_bool(table["value"], "style boolean")
    kind == "string" && return _drawing_string(table["value"], "style string")
    kind == "id" && return ProjectId(_drawing_string(table["value"], "style id"))
    kind == "decimal" && return _parse_drawing_exact(table["value"])
    throw(ArgumentError("unknown drawing style value kind"))
end

function _parse_drawing_workspace(payload)
    collection_names = ["documents", "views", "sheets", "viewports", "layers", "styles", "blocks", "entities", "projections", "routes", "labels", "locks"]
    root = _drawing_map(payload, collection_names, "drawing workspace")
    provenance(value) = _parse_drawing_provenance(value)
    ids(value, role) = ProjectId.(_drawing_string.(value, Ref(role)))
    optional_id(value, role) = _drawing_optional(value, value -> ProjectId(_drawing_string(value, role)))

    documents = map(_drawing_array(root["documents"], "documents")) do value
        table = _drawing_map(value, ["identity", "name", "views", "sheets", "provenance"], "drawing document")
        DrawingDocument(_parse_drawing_identity(table["identity"]), _drawing_string(table["name"], "document name"), ids(_drawing_array(table["views"], "document views"), "view id"), ids(_drawing_array(table["sheets"], "document sheets"), "sheet id"), provenance(table["provenance"]))
    end
    views = map(_drawing_array(root["views"], "views")) do value
        table = _drawing_map(value, ["identity", "document", "name", "space", "semantic_view", "provenance"], "drawing view")
        space = Dict("model" => DrawingModelSpace, "paper" => DrawingPaperSpace)[_drawing_string(table["space"], "drawing space")]
        DrawingView(_parse_drawing_identity(table["identity"]), ProjectId(_drawing_string(table["document"], "document id")), _drawing_string(table["name"], "view name"), space, provenance(table["provenance"]); semantic_view = optional_id(table["semantic_view"], "semantic view id"))
    end
    sheets = map(_drawing_array(root["sheets"], "sheets")) do value
        table = _drawing_map(value, ["identity", "document", "view", "name", "width", "height", "provenance"], "drawing sheet")
        DrawingSheet(_parse_drawing_identity(table["identity"]), ProjectId(_drawing_string(table["document"], "document id")), ProjectId(_drawing_string(table["view"], "view id")), _drawing_string(table["name"], "sheet name"), _parse_drawing_exact(table["width"]), _parse_drawing_exact(table["height"]), provenance(table["provenance"]))
    end
    viewports = map(_drawing_array(root["viewports"], "viewports")) do value
        table = _drawing_map(value, ["identity", "sheet", "view", "origin", "width", "height", "scale", "rotation_degrees", "visible_layers", "provenance"], "drawing viewport")
        DrawingViewport(_parse_drawing_identity(table["identity"]), ProjectId(_drawing_string(table["sheet"], "sheet id")), ProjectId(_drawing_string(table["view"], "view id")), _parse_drawing_coordinate(table["origin"]), _parse_drawing_exact(table["width"]), _parse_drawing_exact(table["height"]), _parse_drawing_exact(table["scale"]), _parse_drawing_exact(table["rotation_degrees"]), ids(_drawing_array(table["visible_layers"], "visible layers"), "layer id"), provenance(table["provenance"]))
    end
    layers = map(_drawing_array(root["layers"], "layers")) do value
        table = _drawing_map(value, ["identity", "document", "name", "visible", "printable", "provenance"], "drawing layer")
        DrawingLayer(_parse_drawing_identity(table["identity"]), ProjectId(_drawing_string(table["document"], "document id")), _drawing_string(table["name"], "layer name"), provenance(table["provenance"]); visible = _drawing_bool(table["visible"], "layer visibility"), printable = _drawing_bool(table["printable"], "layer printability"))
    end
    style_kinds = Dict("line" => DrawingLineStyle, "text" => DrawingTextStyle, "dimension" => DrawingDimensionStyle, "plot" => DrawingPlotStyle)
    styles = map(_drawing_array(root["styles"], "styles")) do value
        table = _drawing_map(value, ["identity", "document", "name", "kind", "properties", "provenance"], "drawing style")
        properties = map(_drawing_array(table["properties"], "style properties")) do item
            property = _drawing_map(item, ["name", "value"], "style property")
            DrawingStyleProperty(ProjectId(_drawing_string(property["name"], "property name")), _parse_drawing_style_value(property["value"]))
        end
        kind = style_kinds[_drawing_string(table["kind"], "style kind")]
        DrawingStyle(_parse_drawing_identity(table["identity"]), ProjectId(_drawing_string(table["document"], "document id")), _drawing_string(table["name"], "style name"), kind, properties, provenance(table["provenance"]))
    end
    blocks = map(_drawing_array(root["blocks"], "blocks")) do value
        table = _drawing_map(value, ["identity", "document", "name", "base_point", "provenance"], "drawing block")
        DrawingBlockDefinition(_parse_drawing_identity(table["identity"]), ProjectId(_drawing_string(table["document"], "document id")), _drawing_string(table["name"], "block name"), _parse_drawing_coordinate(table["base_point"]), provenance(table["provenance"]))
    end
    entities = map(_drawing_array(root["entities"], "entities")) do value
        table = _drawing_map(value, ["identity", "container", "layer", "kind", "points", "style", "block_definition", "provenance"], "drawing entity")
        points = _parse_drawing_coordinate.(_drawing_array(table["points"], "entity points"))
        DrawingEntity(_parse_drawing_identity(table["identity"]), ProjectId(_drawing_string(table["container"], "container id")), ProjectId(_drawing_string(table["layer"], "layer id")), ProjectId(_drawing_string(table["kind"], "entity kind")), points, provenance(table["provenance"]); style = optional_id(table["style"], "style id"), block_definition = optional_id(table["block_definition"], "block id"))
    end
    projections = map(_drawing_array(root["projections"], "projections")) do value
        table = _drawing_map(value, ["identity", "view", "semantic_projection", "layer", "position", "rotation_degrees", "scale", "provenance"], "drawing projection")
        DrawingProjection(_parse_drawing_identity(table["identity"]), ProjectId(_drawing_string(table["view"], "view id")), ProjectId(_drawing_string(table["semantic_projection"], "semantic projection id")), ProjectId(_drawing_string(table["layer"], "layer id")), _parse_drawing_coordinate(table["position"]), _parse_drawing_exact(table["rotation_degrees"]), _parse_drawing_exact(table["scale"]), provenance(table["provenance"]))
    end
    routes = map(_drawing_array(root["routes"], "routes")) do value
        table = _drawing_map(value, ["identity", "view", "layer", "semantic_connection", "points", "style", "provenance"], "drawing route")
        DrawingRoute(_parse_drawing_identity(table["identity"]), ProjectId(_drawing_string(table["view"], "view id")), ProjectId(_drawing_string(table["layer"], "layer id")), _parse_drawing_coordinate.(_drawing_array(table["points"], "route points")), provenance(table["provenance"]); semantic_connection = optional_id(table["semantic_connection"], "connection id"), style = optional_id(table["style"], "style id"))
    end
    labels = map(_drawing_array(root["labels"], "labels")) do value
        table = _drawing_map(value, ["identity", "view", "layer", "anchor", "text", "style", "bound_owner", "bound_field", "provenance"], "drawing label")
        DrawingLabel(_parse_drawing_identity(table["identity"]), ProjectId(_drawing_string(table["view"], "view id")), ProjectId(_drawing_string(table["layer"], "layer id")), _parse_drawing_coordinate(table["anchor"]), _drawing_string(table["text"], "label text"), provenance(table["provenance"]); style = optional_id(table["style"], "style id"), bound_owner = optional_id(table["bound_owner"], "bound owner id"), bound_field = _drawing_optional(table["bound_field"], value -> _drawing_string(value, "bound field")))
    end
    lock_aspects = Dict("position" => DrawingPositionLock, "geometry" => DrawingGeometryLock, "content" => DrawingContentLock, "visibility" => DrawingVisibilityLock)
    locks = map(_drawing_array(root["locks"], "locks")) do value
        table = _drawing_map(value, ["identity", "owner", "aspects", "reason", "provenance"], "drawing lock")
        aspects = [lock_aspects[_drawing_string(item, "lock aspect")] for item in _drawing_array(table["aspects"], "lock aspects")]
        DrawingLock(_parse_drawing_identity(table["identity"]), ProjectId(_drawing_string(table["owner"], "lock owner")), aspects, provenance(table["provenance"]); reason = _drawing_string(table["reason"], "lock reason"))
    end
    return DrawingWorkspace(; documents, views, sheets, viewports, layers, styles, blocks, entities, projections, routes, labels, locks)
end

function _native_symbol(binding::DrawingSymbolBinding)
    return AIMORAFormats.NativeSymbolReference(
        binding.owner.value,
        binding.symbol_id,
        binding.library_id,
        binding.content_sha256;
        state = binding.state,
        level_of_detail = binding.level_of_detail,
    )
end

function serialize_drawing_workspace(
    project_id::ProjectId,
    workspace::DrawingWorkspace;
    symbols::AbstractVector{DrawingSymbolBinding} = DrawingSymbolBinding[],
    caches::AbstractVector{AIMORAFormats.NativeDrawingCacheReference} = AIMORAFormats.NativeDrawingCacheReference[],
    policy::AIMORAFormats.FormatInputPolicy = AIMORAFormats.FormatInputPolicy(),
)
    _validate_drawing_symbol_bindings(workspace, symbols)
    document = AIMORAFormats.NativeDrawingDocument(
        project_id.value,
        _drawing_workspace_data(workspace),
        _native_symbol.(symbols),
        caches,
    )
    return AIMORAFormats.serialize_native_drawing(document; policy)
end

function drawing_workspace_sha256(
    project_id::ProjectId,
    workspace::DrawingWorkspace;
    symbols::AbstractVector{DrawingSymbolBinding} = DrawingSymbolBinding[],
    caches::AbstractVector{AIMORAFormats.NativeDrawingCacheReference} = AIMORAFormats.NativeDrawingCacheReference[],
    policy::AIMORAFormats.FormatInputPolicy = AIMORAFormats.FormatInputPolicy(),
)
    _validate_drawing_symbol_bindings(workspace, symbols)
    document = AIMORAFormats.NativeDrawingDocument(project_id.value, _drawing_workspace_data(workspace), _native_symbol.(symbols), caches)
    return AIMORAFormats.native_drawing_sha256(document; policy)
end

function parse_drawing_workspace(
    input::Union{AbstractString,AbstractVector{UInt8}};
    source_name::AbstractString = "<memory>",
    policy::AIMORAFormats.FormatInputPolicy = AIMORAFormats.FormatInputPolicy(),
    available_cache_hashes::AbstractDict = Dict{String,String}(),
)
    parsed = AIMORAFormats.parse_native_drawing(input; source_name, policy, available_cache_hashes)
    AIMORAFormats.format_succeeded(parsed) ||
        return DrawingWorkspaceReadResult(nothing, collect(parsed.diagnostics))
    try
        workspace = _parse_drawing_workspace(AIMORAFormats.native_drawing_payload(parsed.value.document))
        symbols = DrawingSymbolBinding[
            DrawingSymbolBinding(
                ProjectId(reference.owner_id),
                reference.symbol_id,
                reference.library_id,
                reference.content_sha256;
                state = reference.state,
                level_of_detail = reference.level_of_detail,
            ) for reference in parsed.value.document.symbols
        ]
        value = DrawingWorkspaceDocument(
            ProjectId(parsed.value.document.project_id),
            workspace,
            symbols,
            parsed.value.migration,
            collect(parsed.value.missing_cache_paths),
        )
        return DrawingWorkspaceReadResult(value)
    catch error
        error isa ArgumentError || error isa KeyError || rethrow()
        diagnostic = AIMORAFormats.FormatDiagnostic(
            AIMORAFormats.DiagnosticError,
            :invalid_drawing_workspace,
            sprint(showerror, error),
        )
        return DrawingWorkspaceReadResult(nothing, [diagnostic])
    end
end

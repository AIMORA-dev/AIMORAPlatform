"""Canonical drawing records with exact coordinates and separated semantic references."""

@enum DrawingSpace::UInt8 begin
    DrawingModelSpace = 0x01
    DrawingPaperSpace = 0x02
end

@enum DrawingStyleKind::UInt8 begin
    DrawingLineStyle = 0x01
    DrawingTextStyle = 0x02
    DrawingDimensionStyle = 0x03
    DrawingPlotStyle = 0x04
end

@enum DrawingLockAspect::UInt8 begin
    DrawingPositionLock = 0x01
    DrawingGeometryLock = 0x02
    DrawingContentLock = 0x03
    DrawingVisibilityLock = 0x04
end

function _drawing_text(value::AbstractString, role::AbstractString; allow_empty::Bool = false)
    normalized = String(value)
    isvalid(normalized) ||
        _semantic_fail(:invalid_drawing_text, String(role) * " must be valid Unicode")
    occursin('\0', normalized) &&
        _semantic_fail(:invalid_drawing_text, String(role) * " contains NUL")
    !allow_empty && isempty(strip(normalized)) &&
        _semantic_fail(:invalid_drawing_text, String(role) * " must not be empty")
    return normalized
end

function _drawing_id_list(
    values::AbstractVector{ProjectId},
    duplicate_code::Symbol,
    duplicate_message::AbstractString,
)
    copied = sort!(collect(values); by = value -> value.value)
    length(copied) == length(unique(copied)) ||
        _semantic_fail(duplicate_code, duplicate_message)
    return CanonicalList{ProjectId}(copied)
end

"""One exact Cartesian coordinate in drawing units."""
struct DrawingCoordinate
    x::ExactDecimal
    y::ExactDecimal
end

Base.:(==)(left::DrawingCoordinate, right::DrawingCoordinate) =
    left.x == right.x && left.y == right.y

const DrawingStyleValue = Union{Bool,ExactDecimal,ProjectId,String}

"""One deterministic, typed style property."""
struct DrawingStyleProperty
    name::ProjectId
    value::DrawingStyleValue

    function DrawingStyleProperty(name::ProjectId, value)
        value isa Union{Bool,ExactDecimal,ProjectId,AbstractString} ||
            _semantic_fail(
                :invalid_drawing_style_value,
                "drawing style values must be Boolean, exact decimal, project ID, or text",
            )
        normalized = value isa AbstractString ?
            _drawing_text(value, "drawing style value"; allow_empty = true) :
            value
        return new(name, normalized)
    end
end

Base.:(==)(left::DrawingStyleProperty, right::DrawingStyleProperty) =
    left.name == right.name && left.value == right.value

"""One model-space or paper-space view owned by a drawing document."""
struct DrawingView
    identity::ObjectIdentity
    document::ProjectId
    name::String
    space::DrawingSpace
    semantic_view::Union{Nothing,ProjectId}
    provenance::ProvenanceSource

    function DrawingView(
        identity::ObjectIdentity,
        document::ProjectId,
        name::AbstractString,
        space::DrawingSpace,
        provenance::ProvenanceSource;
        semantic_view::Union{Nothing,ProjectId} = nothing,
    )
        normalized = _drawing_text(name, "drawing view name")
        space == DrawingPaperSpace && !isnothing(semantic_view) &&
            _semantic_fail(
                :semantic_paper_view,
                "paper-space drawing views cannot own semantic projections",
            )
        return new(identity, document, normalized, space, semantic_view, provenance)
    end
end

Base.:(==)(left::DrawingView, right::DrawingView) =
    left.identity == right.identity &&
    left.document == right.document &&
    left.name == right.name &&
    left.space == right.space &&
    left.semantic_view == right.semantic_view &&
    left.provenance == right.provenance

"""One stable drawing document and its complete view and sheet membership."""
struct DrawingDocument
    identity::ObjectIdentity
    name::String
    views::CanonicalList{ProjectId}
    sheets::CanonicalList{ProjectId}
    provenance::ProvenanceSource

    function DrawingDocument(
        identity::ObjectIdentity,
        name::AbstractString,
        views::AbstractVector{ProjectId},
        sheets::AbstractVector{ProjectId},
        provenance::ProvenanceSource,
    )
        normalized = _drawing_text(name, "drawing document name")
        view_ids = _drawing_id_list(
            views,
            :duplicate_document_view,
            "drawing document repeats a view ID",
        )
        isempty(view_ids) &&
            _semantic_fail(:missing_document_view, "drawing document requires at least one view")
        sheet_ids = _drawing_id_list(
            sheets,
            :duplicate_document_sheet,
            "drawing document repeats a sheet ID",
        )
        return new(identity, normalized, view_ids, sheet_ids, provenance)
    end
end

Base.:(==)(left::DrawingDocument, right::DrawingDocument) =
    left.identity == right.identity &&
    left.name == right.name &&
    left.views == right.views &&
    left.sheets == right.sheets &&
    left.provenance == right.provenance

"""One paper sheet linked to exactly one paper-space view."""
struct DrawingSheet
    identity::ObjectIdentity
    document::ProjectId
    view::ProjectId
    name::String
    width::ExactDecimal
    height::ExactDecimal
    provenance::ProvenanceSource

    function DrawingSheet(
        identity::ObjectIdentity,
        document::ProjectId,
        view::ProjectId,
        name::AbstractString,
        width::ExactDecimal,
        height::ExactDecimal,
        provenance::ProvenanceSource,
    )
        normalized = _drawing_text(name, "drawing sheet name")
        exact_rational(width) > ExactRational(0) &&
            exact_rational(height) > ExactRational(0) ||
            _semantic_fail(
                :invalid_sheet_geometry,
                "drawing sheet width and height must be strictly positive",
            )
        return new(identity, document, view, normalized, width, height, provenance)
    end
end

Base.:(==)(left::DrawingSheet, right::DrawingSheet) =
    left.identity == right.identity &&
    left.document == right.document &&
    left.view == right.view &&
    left.name == right.name &&
    left.width == right.width &&
    left.height == right.height &&
    left.provenance == right.provenance

"""One named layer with explicit screen and publication behavior."""
struct DrawingLayer
    identity::ObjectIdentity
    document::ProjectId
    name::String
    visible::Bool
    printable::Bool
    provenance::ProvenanceSource

    function DrawingLayer(
        identity::ObjectIdentity,
        document::ProjectId,
        name::AbstractString,
        provenance::ProvenanceSource;
        visible::Bool = true,
        printable::Bool = true,
    )
        return new(
            identity,
            document,
            _drawing_text(name, "drawing layer name"),
            visible,
            printable,
            provenance,
        )
    end
end

Base.:(==)(left::DrawingLayer, right::DrawingLayer) =
    left.identity == right.identity &&
    left.document == right.document &&
    left.name == right.name &&
    left.visible == right.visible &&
    left.printable == right.printable &&
    left.provenance == right.provenance

"""One reusable deterministic line, text, dimension, or plot style."""
struct DrawingStyle
    identity::ObjectIdentity
    document::ProjectId
    name::String
    kind::DrawingStyleKind
    properties::CanonicalList{DrawingStyleProperty}
    provenance::ProvenanceSource

    function DrawingStyle(
        identity::ObjectIdentity,
        document::ProjectId,
        name::AbstractString,
        kind::DrawingStyleKind,
        properties::AbstractVector{DrawingStyleProperty},
        provenance::ProvenanceSource,
    )
        copied = sort!(collect(properties); by = property -> property.name.value)
        names = getfield.(copied, :name)
        length(names) == length(unique(names)) ||
            _semantic_fail(:duplicate_drawing_style_property, "drawing style repeats a property")
        return new(
            identity,
            document,
            _drawing_text(name, "drawing style name"),
            kind,
            CanonicalList{DrawingStyleProperty}(copied),
            provenance,
        )
    end
end

Base.:(==)(left::DrawingStyle, right::DrawingStyle) =
    left.identity == right.identity &&
    left.document == right.document &&
    left.name == right.name &&
    left.kind == right.kind &&
    left.properties == right.properties &&
    left.provenance == right.provenance

"""One reusable block definition; member entities reference this ID as their container."""
struct DrawingBlockDefinition
    identity::ObjectIdentity
    document::ProjectId
    name::String
    base_point::DrawingCoordinate
    provenance::ProvenanceSource

    function DrawingBlockDefinition(
        identity::ObjectIdentity,
        document::ProjectId,
        name::AbstractString,
        base_point::DrawingCoordinate,
        provenance::ProvenanceSource,
    )
        return new(
            identity,
            document,
            _drawing_text(name, "drawing block name"),
            base_point,
            provenance,
        )
    end
end

Base.:(==)(left::DrawingBlockDefinition, right::DrawingBlockDefinition) =
    left.identity == right.identity &&
    left.document == right.document &&
    left.name == right.name &&
    left.base_point == right.base_point &&
    left.provenance == right.provenance

"""One exact drafting entity contained by a view or reusable block."""
struct DrawingEntity
    identity::ObjectIdentity
    container::ProjectId
    layer::ProjectId
    kind::ProjectId
    points::CanonicalList{DrawingCoordinate}
    style::Union{Nothing,ProjectId}
    block_definition::Union{Nothing,ProjectId}
    provenance::ProvenanceSource

    function DrawingEntity(
        identity::ObjectIdentity,
        container::ProjectId,
        layer::ProjectId,
        kind::ProjectId,
        points::AbstractVector{DrawingCoordinate},
        provenance::ProvenanceSource;
        style::Union{Nothing,ProjectId} = nothing,
        block_definition::Union{Nothing,ProjectId} = nothing,
    )
        copied = collect(points)
        isempty(copied) &&
            _semantic_fail(:missing_drawing_geometry, "drawing entity requires exact geometry")
        return new(
            identity,
            container,
            layer,
            kind,
            CanonicalList{DrawingCoordinate}(copied),
            style,
            block_definition,
            provenance,
        )
    end
end

Base.:(==)(left::DrawingEntity, right::DrawingEntity) =
    left.identity == right.identity &&
    left.container == right.container &&
    left.layer == right.layer &&
    left.kind == right.kind &&
    left.points == right.points &&
    left.style == right.style &&
    left.block_definition == right.block_definition &&
    left.provenance == right.provenance

"""Geometry for one semantic graph projection inside a model-space drawing view."""
struct DrawingProjection
    identity::ObjectIdentity
    view::ProjectId
    semantic_projection::ProjectId
    layer::ProjectId
    position::DrawingCoordinate
    rotation_degrees::ExactDecimal
    scale::ExactDecimal
    provenance::ProvenanceSource

    function DrawingProjection(
        identity::ObjectIdentity,
        view::ProjectId,
        semantic_projection::ProjectId,
        layer::ProjectId,
        position::DrawingCoordinate,
        rotation_degrees::ExactDecimal,
        scale::ExactDecimal,
        provenance::ProvenanceSource,
    )
        exact_rational(scale) > ExactRational(0) ||
            _semantic_fail(:invalid_drawing_scale, "drawing projection scale must be positive")
        return new(
            identity,
            view,
            semantic_projection,
            layer,
            position,
            rotation_degrees,
            scale,
            provenance,
        )
    end
end

Base.:(==)(left::DrawingProjection, right::DrawingProjection) =
    left.identity == right.identity &&
    left.view == right.view &&
    left.semantic_projection == right.semantic_projection &&
    left.layer == right.layer &&
    left.position == right.position &&
    left.rotation_degrees == right.rotation_degrees &&
    left.scale == right.scale &&
    left.provenance == right.provenance

"""One exact connection route; drafting routes have no semantic connection."""
struct DrawingRoute
    identity::ObjectIdentity
    view::ProjectId
    layer::ProjectId
    semantic_connection::Union{Nothing,ProjectId}
    points::CanonicalList{DrawingCoordinate}
    style::Union{Nothing,ProjectId}
    provenance::ProvenanceSource

    function DrawingRoute(
        identity::ObjectIdentity,
        view::ProjectId,
        layer::ProjectId,
        points::AbstractVector{DrawingCoordinate},
        provenance::ProvenanceSource;
        semantic_connection::Union{Nothing,ProjectId} = nothing,
        style::Union{Nothing,ProjectId} = nothing,
    )
        copied = collect(points)
        length(copied) >= 2 ||
            _semantic_fail(:invalid_route_geometry, "drawing route requires at least two points")
        return new(
            identity,
            view,
            layer,
            semantic_connection,
            CanonicalList{DrawingCoordinate}(copied),
            style,
            provenance,
        )
    end
end

Base.:(==)(left::DrawingRoute, right::DrawingRoute) =
    left.identity == right.identity &&
    left.view == right.view &&
    left.layer == right.layer &&
    left.semantic_connection == right.semantic_connection &&
    left.points == right.points &&
    left.style == right.style &&
    left.provenance == right.provenance

"""One visible label with an optional explicit semantic field binding."""
struct DrawingLabel
    identity::ObjectIdentity
    view::ProjectId
    layer::ProjectId
    anchor::DrawingCoordinate
    text::String
    style::Union{Nothing,ProjectId}
    bound_owner::Union{Nothing,ProjectId}
    bound_field::Union{Nothing,String}
    provenance::ProvenanceSource

    function DrawingLabel(
        identity::ObjectIdentity,
        view::ProjectId,
        layer::ProjectId,
        anchor::DrawingCoordinate,
        text::AbstractString,
        provenance::ProvenanceSource;
        style::Union{Nothing,ProjectId} = nothing,
        bound_owner::Union{Nothing,ProjectId} = nothing,
        bound_field::Union{Nothing,AbstractString} = nothing,
    )
        normalized = _drawing_text(text, "drawing label text"; allow_empty = true)
        isnothing(bound_owner) == isnothing(bound_field) ||
            _semantic_fail(
                :incomplete_drawing_label_binding,
                "drawing label binding requires both owner and field",
            )
        field = isnothing(bound_field) ? nothing : String(bound_field)
        !isnothing(field) && !occursin(r"^[a-z][a-z0-9_]*$", field) &&
            _semantic_fail(
                :invalid_drawing_label_field,
                "drawing label field must be lowercase portable text",
            )
        isempty(normalized) && isnothing(bound_owner) &&
            _semantic_fail(
                :empty_drawing_label,
                "drawing label requires text or a semantic binding",
            )
        return new(
            identity,
            view,
            layer,
            anchor,
            normalized,
            style,
            bound_owner,
            field,
            provenance,
        )
    end
end

Base.:(==)(left::DrawingLabel, right::DrawingLabel) =
    left.identity == right.identity &&
    left.view == right.view &&
    left.layer == right.layer &&
    left.anchor == right.anchor &&
    left.text == right.text &&
    left.style == right.style &&
    left.bound_owner == right.bound_owner &&
    left.bound_field == right.bound_field &&
    left.provenance == right.provenance

"""One model-space viewport framed on a paper sheet."""
struct DrawingViewport
    identity::ObjectIdentity
    sheet::ProjectId
    view::ProjectId
    origin::DrawingCoordinate
    width::ExactDecimal
    height::ExactDecimal
    scale::ExactDecimal
    rotation_degrees::ExactDecimal
    visible_layers::CanonicalList{ProjectId}
    provenance::ProvenanceSource

    function DrawingViewport(
        identity::ObjectIdentity,
        sheet::ProjectId,
        view::ProjectId,
        origin::DrawingCoordinate,
        width::ExactDecimal,
        height::ExactDecimal,
        scale::ExactDecimal,
        rotation_degrees::ExactDecimal,
        visible_layers::AbstractVector{ProjectId},
        provenance::ProvenanceSource,
    )
        exact_rational(width) > ExactRational(0) &&
            exact_rational(height) > ExactRational(0) ||
            _semantic_fail(
                :invalid_viewport_geometry,
                "viewport width and height must be strictly positive",
            )
        exact_rational(scale) > ExactRational(0) ||
            _semantic_fail(:invalid_drawing_scale, "drawing viewport scale must be positive")
        layers = _drawing_id_list(
            visible_layers,
            :duplicate_viewport_layer,
            "drawing viewport repeats a visible layer",
        )
        return new(
            identity,
            sheet,
            view,
            origin,
            width,
            height,
            scale,
            rotation_degrees,
            layers,
            provenance,
        )
    end
end

Base.:(==)(left::DrawingViewport, right::DrawingViewport) =
    left.identity == right.identity &&
    left.sheet == right.sheet &&
    left.view == right.view &&
    left.origin == right.origin &&
    left.width == right.width &&
    left.height == right.height &&
    left.scale == right.scale &&
    left.rotation_degrees == right.rotation_degrees &&
    left.visible_layers == right.visible_layers &&
    left.provenance == right.provenance

"""One explicit lock over selected mutation aspects of a drawing record."""
struct DrawingLock
    identity::ObjectIdentity
    owner::ProjectId
    aspects::CanonicalList{DrawingLockAspect}
    reason::String
    provenance::ProvenanceSource

    function DrawingLock(
        identity::ObjectIdentity,
        owner::ProjectId,
        aspects::AbstractVector{DrawingLockAspect},
        provenance::ProvenanceSource;
        reason::AbstractString = "",
    )
        copied = sort!(collect(aspects); by = UInt8)
        isempty(copied) &&
            _semantic_fail(:empty_drawing_lock, "drawing lock requires at least one aspect")
        length(copied) == length(unique(copied)) ||
            _semantic_fail(:duplicate_drawing_lock_aspect, "drawing lock repeats an aspect")
        return new(
            identity,
            owner,
            CanonicalList{DrawingLockAspect}(copied),
            _drawing_text(reason, "drawing lock reason"; allow_empty = true),
            provenance,
        )
    end
end

Base.:(==)(left::DrawingLock, right::DrawingLock) =
    left.identity == right.identity &&
    left.owner == right.owner &&
    left.aspects == right.aspects &&
    left.reason == right.reason &&
    left.provenance == right.provenance

const CanonicalDrawingRecord = Union{
    DrawingDocument,
    DrawingView,
    DrawingSheet,
    DrawingViewport,
    DrawingLayer,
    DrawingStyle,
    DrawingBlockDefinition,
    DrawingEntity,
    DrawingProjection,
    DrawingRoute,
    DrawingLabel,
    DrawingLock,
}

struct AddDrawingRecordPatch <: ProjectPatch
    record::CanonicalDrawingRecord
end

struct ReplaceDrawingRecordPatch <: ProjectPatch
    record::CanonicalDrawingRecord
end

struct RemoveDrawingRecordPatch <: ProjectPatch
    owner::ProjectId
end

Base.:(==)(left::AddDrawingRecordPatch, right::AddDrawingRecordPatch) =
    left.record == right.record
Base.:(==)(left::ReplaceDrawingRecordPatch, right::ReplaceDrawingRecordPatch) =
    left.record == right.record
Base.:(==)(left::RemoveDrawingRecordPatch, right::RemoveDrawingRecordPatch) =
    left.owner == right.owner

"""A canonically ordered immutable drawing workspace."""
struct DrawingWorkspace
    documents::CanonicalList{DrawingDocument}
    views::CanonicalList{DrawingView}
    sheets::CanonicalList{DrawingSheet}
    viewports::CanonicalList{DrawingViewport}
    layers::CanonicalList{DrawingLayer}
    styles::CanonicalList{DrawingStyle}
    blocks::CanonicalList{DrawingBlockDefinition}
    entities::CanonicalList{DrawingEntity}
    projections::CanonicalList{DrawingProjection}
    routes::CanonicalList{DrawingRoute}
    labels::CanonicalList{DrawingLabel}
    locks::CanonicalList{DrawingLock}

    function DrawingWorkspace(;
        documents::AbstractVector{DrawingDocument} = DrawingDocument[],
        views::AbstractVector{DrawingView} = DrawingView[],
        sheets::AbstractVector{DrawingSheet} = DrawingSheet[],
        viewports::AbstractVector{DrawingViewport} = DrawingViewport[],
        layers::AbstractVector{DrawingLayer} = DrawingLayer[],
        styles::AbstractVector{DrawingStyle} = DrawingStyle[],
        blocks::AbstractVector{DrawingBlockDefinition} = DrawingBlockDefinition[],
        entities::AbstractVector{DrawingEntity} = DrawingEntity[],
        projections::AbstractVector{DrawingProjection} = DrawingProjection[],
        routes::AbstractVector{DrawingRoute} = DrawingRoute[],
        labels::AbstractVector{DrawingLabel} = DrawingLabel[],
        locks::AbstractVector{DrawingLock} = DrawingLock[],
    )
        ordered(items::AbstractVector{T}) where {T} =
            CanonicalList{T}(sort!(collect(items); by = item -> item.identity.id.value))
        collections = (
            ordered(documents),
            ordered(views),
            ordered(sheets),
            ordered(viewports),
            ordered(layers),
            ordered(styles),
            ordered(blocks),
            ordered(entities),
            ordered(projections),
            ordered(routes),
            ordered(labels),
            ordered(locks),
        )
        ids = ProjectId[]
        for collection in collections
            append!(ids, (item.identity.id for item in collection))
        end
        length(ids) == length(unique(ids)) ||
            _semantic_fail(:duplicate_drawing_id, "drawing workspace repeats a global ID")
        return new(collections...)
    end
end

Base.:(==)(left::DrawingWorkspace, right::DrawingWorkspace) =
    left.documents == right.documents &&
    left.views == right.views &&
    left.sheets == right.sheets &&
    left.viewports == right.viewports &&
    left.layers == right.layers &&
    left.styles == right.styles &&
    left.blocks == right.blocks &&
    left.entities == right.entities &&
    left.projections == right.projections &&
    left.routes == right.routes &&
    left.labels == right.labels &&
    left.locks == right.locks

function _drawing_records(workspace::DrawingWorkspace)
    records = CanonicalDrawingRecord[]
    for collection in (
        workspace.documents,
        workspace.views,
        workspace.sheets,
        workspace.viewports,
        workspace.layers,
        workspace.styles,
        workspace.blocks,
        workspace.entities,
        workspace.projections,
        workspace.routes,
        workspace.labels,
        workspace.locks,
    )
        append!(records, collection)
    end
    return records
end

"""Return all stable drawing IDs."""
drawing_workspace_ids(workspace::DrawingWorkspace) =
    Set(record.identity.id for record in _drawing_records(workspace))

"""Resolve one drawing record by stable identity."""
function drawing_record(workspace::DrawingWorkspace, id::ProjectId)
    records = _drawing_records(workspace)
    index = findfirst(record -> record.identity.id == id, records)
    isnothing(index) &&
        _semantic_fail(:unknown_drawing_id, "drawing workspace record does not exist")
    return records[index]
end

function _drawing_changed_aspects(before::T, after::T) where {T<:CanonicalDrawingRecord}
    changed = Set{DrawingLockAspect}()
    for name in fieldnames(T)
        name == :identity && continue
        getfield(before, name) == getfield(after, name) && continue
        if name in (:position, :origin, :anchor, :container, :view, :sheet, :layer)
            push!(changed, DrawingPositionLock)
        elseif name in (:points, :base_point)
            push!(changed, DrawingPositionLock)
            push!(changed, DrawingGeometryLock)
        elseif name in (:width, :height, :scale, :rotation_degrees)
            push!(changed, DrawingGeometryLock)
        elseif name in (:visible, :printable, :visible_layers)
            push!(changed, DrawingVisibilityLock)
        else
            push!(changed, DrawingContentLock)
        end
    end
    return changed
end

function _validate_drawing_locks(
    workspace::DrawingWorkspace,
    owner::ProjectId,
    changed::Set{DrawingLockAspect},
)
    for lock in workspace.locks
        lock.owner == owner || continue
        isempty(intersect(changed, Set(lock.aspects))) ||
            _semantic_fail(
                :drawing_record_locked,
                "drawing mutation changes an explicitly locked aspect",
            )
    end
    return true
end

function _drawing_workspace(records::AbstractVector{<:CanonicalDrawingRecord})
    return DrawingWorkspace(
        documents = DrawingDocument[item for item in records if item isa DrawingDocument],
        views = DrawingView[item for item in records if item isa DrawingView],
        sheets = DrawingSheet[item for item in records if item isa DrawingSheet],
        viewports = DrawingViewport[item for item in records if item isa DrawingViewport],
        layers = DrawingLayer[item for item in records if item isa DrawingLayer],
        styles = DrawingStyle[item for item in records if item isa DrawingStyle],
        blocks = DrawingBlockDefinition[
            item for item in records if item isa DrawingBlockDefinition
        ],
        entities = DrawingEntity[item for item in records if item isa DrawingEntity],
        projections = DrawingProjection[item for item in records if item isa DrawingProjection],
        routes = DrawingRoute[item for item in records if item isa DrawingRoute],
        labels = DrawingLabel[item for item in records if item isa DrawingLabel],
        locks = DrawingLock[item for item in records if item isa DrawingLock],
    )
end

function _add_drawing_record(
    workspace::DrawingWorkspace,
    record::CanonicalDrawingRecord,
)
    record.identity.id in drawing_workspace_ids(workspace) &&
        _semantic_fail(:duplicate_drawing_id, "drawing add patch targets an existing ID")
    return _drawing_workspace(vcat(_drawing_records(workspace), [record]))
end

function _replace_drawing_record(
    workspace::DrawingWorkspace,
    replacement::CanonicalDrawingRecord,
)
    records = _drawing_records(workspace)
    index = findfirst(record -> record.identity.id == replacement.identity.id, records)
    isnothing(index) &&
        _semantic_fail(:unknown_drawing_id, "drawing replace patch target does not exist")
    typeof(records[index]) == typeof(replacement) ||
        _semantic_fail(
            :drawing_record_type_mismatch,
            "drawing replacement cannot change the record type bound to an ID",
        )
    records[index] == replacement &&
        _semantic_fail(:no_effect_command, "drawing replacement does not change the record")
    _validate_drawing_locks(
        workspace,
        replacement.identity.id,
        _drawing_changed_aspects(records[index], replacement),
    )
    records[index] = replacement
    return _drawing_workspace(records)
end

function _remove_drawing_record(workspace::DrawingWorkspace, owner::ProjectId)
    records = _drawing_records(workspace)
    index = findfirst(record -> record.identity.id == owner, records)
    isnothing(index) &&
        _semantic_fail(:unknown_drawing_id, "drawing remove patch target does not exist")
    _validate_drawing_locks(
        workspace,
        owner,
        Set([
            DrawingPositionLock,
            DrawingGeometryLock,
            DrawingContentLock,
            DrawingVisibilityLock,
        ]),
    )
    deleteat!(records, index)
    return _drawing_workspace(records)
end

"""Require deterministic replay to reproduce the complete drawing identity set."""
function validate_drawing_replay_identity(
    expected::DrawingWorkspace,
    replayed::DrawingWorkspace,
)
    drawing_workspace_ids(expected) == drawing_workspace_ids(replayed) ||
        _semantic_fail(
            :drawing_replay_id_mismatch,
            "drawing workspace identity changed during deterministic replay",
        )
    return true
end

"""Require undo to restore the complete drawing identity set."""
function validate_drawing_rollback_identity(
    expected::DrawingWorkspace,
    restored::DrawingWorkspace,
)
    drawing_workspace_ids(expected) == drawing_workspace_ids(restored) ||
        _semantic_fail(
            :drawing_rollback_id_mismatch,
            "drawing workspace identity changed during rollback",
        )
    return true
end

function _drawing_record_map(collection)
    return Dict(item.identity.id => item for item in collection)
end

function _drawing_container_document(
    container::ProjectId,
    views::AbstractDict,
    blocks::AbstractDict,
)
    haskey(views, container) && return views[container].document
    haskey(blocks, container) && return blocks[container].document
    _semantic_fail(
        :drawing_container_missing,
        "drawing entity references an unknown view or block container",
    )
end

function _validate_drawing_block_cycles(
    blocks::AbstractDict,
    entities::CanonicalList{DrawingEntity},
)
    dependencies = Dict(id => Set{ProjectId}() for id in keys(blocks))
    for entity in entities
        haskey(blocks, entity.container) || continue
        isnothing(entity.block_definition) || push!(
            dependencies[entity.container],
            entity.block_definition,
        )
    end
    states = Dict{ProjectId,UInt8}()
    function visit(owner::ProjectId)
        state = get(states, owner, 0x00)
        state == 0x01 &&
            _semantic_fail(:recursive_drawing_block, "drawing block references form a cycle")
        state == 0x02 && return
        states[owner] = 0x01
        for dependency in dependencies[owner]
            visit(dependency)
        end
        states[owner] = 0x02
        return
    end
    foreach(visit, keys(blocks))
    return true
end

"""Validate drawing ownership, references, topology separation, and lock consistency."""
function validate_drawing_workspace(project, workspace::DrawingWorkspace)
    documents = _drawing_record_map(workspace.documents)
    views = _drawing_record_map(workspace.views)
    sheets = _drawing_record_map(workspace.sheets)
    layers = _drawing_record_map(workspace.layers)
    styles = _drawing_record_map(workspace.styles)
    blocks = _drawing_record_map(workspace.blocks)
    graph_projections = _drawing_record_map(project.graphs.view_projections)

    semantic_ids = Set([
        project.metadata.identity.id;
        [record.identity.id for record in project.records];
        _graph_element_ids(project.graphs);
        _control_owner_ids(project.control_system);
        _event_scenario_owner_ids(project.event_scenarios);
        _orchestration_owner_ids(project.orchestration);
    ])
    for id in drawing_workspace_ids(workspace)
        id in semantic_ids &&
            _semantic_fail(
                :drawing_identity_collision,
                "drawing identity collides with a semantic project identity",
            )
    end

    for view in workspace.views
        haskey(documents, view.document) ||
            _semantic_fail(:drawing_view_document_missing, "drawing view references unknown document")
        !isnothing(view.semantic_view) && view.semantic_view ∉ semantic_ids &&
            _semantic_fail(:drawing_semantic_view_missing, "drawing view references unknown semantic view")
    end

    for sheet in workspace.sheets
        haskey(documents, sheet.document) ||
            _semantic_fail(:drawing_sheet_document_missing, "drawing sheet references unknown document")
        haskey(views, sheet.view) ||
            _semantic_fail(:drawing_sheet_view_missing, "drawing sheet references unknown view")
        view = views[sheet.view]
        view.document == sheet.document ||
            _semantic_fail(:drawing_document_mismatch, "drawing sheet and paper view belong to different documents")
        view.space == DrawingPaperSpace ||
            _semantic_fail(:drawing_sheet_not_paper_space, "drawing sheet must reference a paper-space view")
    end

    for document in workspace.documents
        listed_views = Set(document.views)
        listed_sheets = Set(document.sheets)
        actual_views = Set(
            view.identity.id for view in workspace.views if view.document == document.identity.id
        )
        actual_sheets = Set(
            sheet.identity.id for sheet in workspace.sheets if
            sheet.document == document.identity.id
        )
        listed_views == actual_views ||
            _semantic_fail(:drawing_document_view_mismatch, "drawing document view membership is incomplete")
        listed_sheets == actual_sheets ||
            _semantic_fail(:drawing_document_sheet_mismatch, "drawing document sheet membership is incomplete")
        any(views[id].space == DrawingModelSpace for id in document.views) ||
            _semantic_fail(:missing_model_space, "drawing document requires a model-space view")
        paper_views = Set(id for id in document.views if views[id].space == DrawingPaperSpace)
        Set(sheets[id].view for id in document.sheets) == paper_views ||
            _semantic_fail(:paper_space_sheet_mismatch, "paper-space views and sheets must pair exactly")
    end

    for layer in workspace.layers
        haskey(documents, layer.document) ||
            _semantic_fail(:drawing_layer_document_missing, "drawing layer references unknown document")
    end
    for style in workspace.styles
        haskey(documents, style.document) ||
            _semantic_fail(:drawing_style_document_missing, "drawing style references unknown document")
    end
    for block in workspace.blocks
        haskey(documents, block.document) ||
            _semantic_fail(:drawing_block_document_missing, "drawing block references unknown document")
    end

    function validate_appearance(
        view_id::ProjectId,
        layer_id::ProjectId,
        style_id::Union{Nothing,ProjectId},
    )
        haskey(views, view_id) ||
            _semantic_fail(:drawing_view_missing, "drawing record references unknown view")
        haskey(layers, layer_id) ||
            _semantic_fail(:drawing_layer_missing, "drawing record references unknown layer")
        document = views[view_id].document
        layers[layer_id].document == document ||
            _semantic_fail(:drawing_document_mismatch, "drawing view and layer belong to different documents")
        if !isnothing(style_id)
            haskey(styles, style_id) ||
                _semantic_fail(:drawing_style_missing, "drawing record references unknown style")
            styles[style_id].document == document ||
                _semantic_fail(:drawing_document_mismatch, "drawing view and style belong to different documents")
        end
        return document
    end

    for viewport in workspace.viewports
        haskey(sheets, viewport.sheet) ||
            _semantic_fail(:drawing_viewport_sheet_missing, "drawing viewport references unknown sheet")
        haskey(views, viewport.view) ||
            _semantic_fail(:drawing_viewport_view_missing, "drawing viewport references unknown view")
        model_view = views[viewport.view]
        model_view.space == DrawingModelSpace ||
            _semantic_fail(:viewport_not_model_space, "drawing viewport must reference model space")
        sheets[viewport.sheet].document == model_view.document ||
            _semantic_fail(:drawing_document_mismatch, "drawing viewport crosses documents")
        for layer_id in viewport.visible_layers
            haskey(layers, layer_id) ||
                _semantic_fail(:drawing_layer_missing, "drawing viewport references unknown layer")
            layers[layer_id].document == model_view.document ||
                _semantic_fail(:drawing_document_mismatch, "drawing viewport layer crosses documents")
        end
    end

    for entity in workspace.entities
        document = _drawing_container_document(entity.container, views, blocks)
        haskey(layers, entity.layer) ||
            _semantic_fail(:drawing_layer_missing, "drawing entity references unknown layer")
        layers[entity.layer].document == document ||
            _semantic_fail(:drawing_document_mismatch, "drawing entity and layer belong to different documents")
        if !isnothing(entity.style)
            haskey(styles, entity.style) ||
                _semantic_fail(:drawing_style_missing, "drawing entity references unknown style")
            styles[entity.style].document == document ||
                _semantic_fail(:drawing_document_mismatch, "drawing entity and style belong to different documents")
        end
        if !isnothing(entity.block_definition)
            haskey(blocks, entity.block_definition) ||
                _semantic_fail(:drawing_block_missing, "drawing entity references unknown block")
            blocks[entity.block_definition].document == document ||
                _semantic_fail(:drawing_document_mismatch, "drawing entity block crosses documents")
        end
    end
    _validate_drawing_block_cycles(blocks, workspace.entities)

    for projection in workspace.projections
        validate_appearance(projection.view, projection.layer, nothing)
        view = views[projection.view]
        view.space == DrawingModelSpace ||
            _semantic_fail(:semantic_projection_not_model_space, "semantic projection requires model space")
        isnothing(view.semantic_view) &&
            _semantic_fail(:missing_semantic_view, "semantic projection view lacks a semantic view identity")
        haskey(graph_projections, projection.semantic_projection) ||
            _semantic_fail(
                :drawing_semantic_projection_missing,
                "drawing projection references unknown semantic projection",
            )
        graph_projections[projection.semantic_projection].view == view.semantic_view ||
            _semantic_fail(
                :drawing_semantic_view_mismatch,
                "drawing and semantic projections refer to different views",
            )
    end

    semantic_connections = Set([
        [connection.identity.id for connection in project.graphs.physical_connections];
        [connection.identity.id for connection in project.graphs.signal_connections];
    ])
    for route in workspace.routes
        validate_appearance(route.view, route.layer, route.style)
        !isnothing(route.semantic_connection) &&
            route.semantic_connection ∉ semantic_connections &&
            _semantic_fail(
                :drawing_connection_missing,
                "drawing route references unknown semantic connection",
            )
    end

    for label in workspace.labels
        validate_appearance(label.view, label.layer, label.style)
        !isnothing(label.bound_owner) && label.bound_owner ∉ semantic_ids &&
            _semantic_fail(
                :drawing_label_owner_missing,
                "drawing label references unknown semantic owner",
            )
    end

    lockable_ids = drawing_workspace_ids(workspace)
    foreach(lock -> delete!(lockable_ids, lock.identity.id), workspace.locks)
    claimed_aspects = Set{Tuple{ProjectId,DrawingLockAspect}}()
    for lock in workspace.locks
        lock.owner in lockable_ids ||
            _semantic_fail(:drawing_lock_owner_missing, "drawing lock references unknown owner")
        for aspect in lock.aspects
            key = (lock.owner, aspect)
            key in claimed_aspects &&
                _semantic_fail(
                    :duplicate_drawing_lock,
                    "drawing owner has more than one lock for the same aspect",
                )
            push!(claimed_aspects, key)
        end
    end
    return true
end

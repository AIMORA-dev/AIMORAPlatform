@enum LayoutMode begin
    LayoutInitial
    LayoutFull
    LayoutLocal
    LayoutIncremental
end

@enum LayoutOrientation begin
    LayoutTopDown
    LayoutLeftToRight
end

struct LayoutNodeMetric
    semantic_owner::ProjectId
    width::Int
    height::Int

    function LayoutNodeMetric(semantic_owner::ProjectId, width::Integer, height::Integer)
        width > 0 || throw(ArgumentError("layout node width must be positive"))
        height > 0 || throw(ArgumentError("layout node height must be positive"))
        return new(semantic_owner, Int(width), Int(height))
    end
end

struct LayoutLabelSpec
    semantic_owner::ProjectId
    text::String

    function LayoutLabelSpec(semantic_owner::ProjectId, text::AbstractString)
        isempty(strip(text)) && throw(ArgumentError("layout label text cannot be blank"))
        return new(semantic_owner, String(text))
    end
end

struct RepeatedBaySpec
    identity::ProjectId
    members::Vector{ProjectId}
    label::String

    function RepeatedBaySpec(
        identity::ProjectId,
        members::AbstractVector{ProjectId},
        label::AbstractString,
    )
        normalized = sort!(unique(collect(members)); by = id -> id.value)
        isempty(normalized) && throw(ArgumentError("a repeated bay needs at least one member"))
        return new(identity, normalized, String(label))
    end
end

struct LayoutOptions
    grid::Int
    column_gap::Int
    row_gap::Int
    clearance::Int
    default_node_width::Int
    default_node_height::Int
    page_width::Int
    page_height::Int
    page_margin::Int
    orientation::LayoutOrientation
    materialize_pages::Bool

    function LayoutOptions(
        grid::Integer,
        column_gap::Integer,
        row_gap::Integer,
        clearance::Integer,
        default_node_width::Integer,
        default_node_height::Integer,
        page_width::Integer,
        page_height::Integer,
        page_margin::Integer,
        orientation::LayoutOrientation,
        materialize_pages::Bool,
    )
        dimensions = (
            grid,
            column_gap,
            row_gap,
            clearance,
            default_node_width,
            default_node_height,
            page_width,
            page_height,
        )
        all(>(0), dimensions) || throw(ArgumentError("layout dimensions must be positive"))
        page_margin >= 0 || throw(ArgumentError("page margin cannot be negative"))
        2 * page_margin < page_width ||
            throw(ArgumentError("page margin leaves no horizontal drawing area"))
        2 * page_margin < page_height ||
            throw(ArgumentError("page margin leaves no vertical drawing area"))
        return new(
            Int(grid),
            Int(column_gap),
            Int(row_gap),
            Int(clearance),
            Int(default_node_width),
            Int(default_node_height),
            Int(page_width),
            Int(page_height),
            Int(page_margin),
            orientation,
            materialize_pages,
        )
    end
end

LayoutOptions(;
    grid::Integer = 10,
    column_gap::Integer = 40,
    row_gap::Integer = 70,
    clearance::Integer = 10,
    default_node_width::Integer = 60,
    default_node_height::Integer = 40,
    page_width::Integer = 840,
    page_height::Integer = 594,
    page_margin::Integer = 30,
    orientation::LayoutOrientation = LayoutTopDown,
    materialize_pages::Bool = true,
) = LayoutOptions(
    grid,
    column_gap,
    row_gap,
    clearance,
    default_node_width,
    default_node_height,
    page_width,
    page_height,
    page_margin,
    orientation,
    materialize_pages,
)

struct LayoutRequest
    mode::LayoutMode
    view::ProjectId
    layer::ProjectId
    focus::Vector{ProjectId}
    manual_records::Vector{ProjectId}
    node_metrics::Vector{LayoutNodeMetric}
    labels::Vector{LayoutLabelSpec}
    repeated_bays::Vector{RepeatedBaySpec}
    rank_hints::Vector{Pair{ProjectId,Int}}
    origin_x::Int
    origin_y::Int
    options::LayoutOptions
    provenance::ProvenanceSource
end

function LayoutRequest(
    view::ProjectId,
    layer::ProjectId,
    provenance::ProvenanceSource;
    mode::LayoutMode = LayoutInitial,
    focus::AbstractVector{ProjectId} = ProjectId[],
    manual_records::AbstractVector{ProjectId} = ProjectId[],
    node_metrics::AbstractVector{LayoutNodeMetric} = LayoutNodeMetric[],
    labels::AbstractVector{LayoutLabelSpec} = LayoutLabelSpec[],
    repeated_bays::AbstractVector{RepeatedBaySpec} = RepeatedBaySpec[],
    rank_hints::AbstractVector{<:Pair{ProjectId,<:Integer}} = Pair{ProjectId,Int}[],
    origin_x::Integer = 0,
    origin_y::Integer = 0,
    options::LayoutOptions = LayoutOptions(),
)
    normalized_focus = sort!(unique(collect(focus)); by = id -> id.value)
    normalized_manual = sort!(unique(collect(manual_records)); by = id -> id.value)
    normalized_metrics = sort!(collect(node_metrics); by = metric -> metric.semantic_owner.value)
    normalized_labels = sort!(collect(labels); by = label -> label.semantic_owner.value)
    normalized_bays = sort!(collect(repeated_bays); by = bay -> bay.identity.value)
    normalized_hints = Pair{ProjectId,Int}[
        first(hint) => Int(last(hint)) for hint in rank_hints
    ]
    sort!(normalized_hints; by = hint -> first(hint).value)
    all(last(hint) >= 0 for hint in normalized_hints) ||
        throw(ArgumentError("layout rank hints cannot be negative"))
    return LayoutRequest(
        mode,
        view,
        layer,
        normalized_focus,
        normalized_manual,
        normalized_metrics,
        normalized_labels,
        normalized_bays,
        normalized_hints,
        Int(origin_x),
        Int(origin_y),
        options,
        provenance,
    )
end

struct LayoutPlacement
    semantic_owner::ProjectId
    semantic_projection::ProjectId
    drawing_projection::ProjectId
    position::DrawingCoordinate
    width::Int
    height::Int
    rank::Int
    page::Int
    moved::Bool
end

struct LayoutRoutePlan
    semantic_connection::ProjectId
    drawing_route::ProjectId
    points::Vector{DrawingCoordinate}
end

struct LayoutLabelPlan
    semantic_owner::Union{Nothing,ProjectId}
    drawing_label::ProjectId
    anchor::DrawingCoordinate
    text::String
end

struct LayoutBoundary
    drawing_entity::ProjectId
    repeated_bay::ProjectId
    points::Vector{DrawingCoordinate}
    label::String
end

struct LayoutPage
    index::Int
    lower_left::DrawingCoordinate
    upper_right::DrawingCoordinate
    members::Vector{ProjectId}
end

struct LayoutPlan
    mode::LayoutMode
    view::ProjectId
    placements::Vector{LayoutPlacement}
    routes::Vector{LayoutRoutePlan}
    labels::Vector{LayoutLabelPlan}
    boundaries::Vector{LayoutBoundary}
    pages::Vector{LayoutPage}
end

struct LayoutResult
    project::CanonicalProject
    plan::LayoutPlan
    physics_hash_before::ContentDigest
    physics_hash_after::ContentDigest
end

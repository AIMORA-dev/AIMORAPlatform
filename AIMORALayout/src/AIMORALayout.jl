"""Deterministic, topology-safe layout for canonical AIMORA drawings."""
module AIMORALayout

using AIMORAProject

include("layout_types.jl")
include("layout_engine.jl")

export LayoutBoundary,
       LayoutFull,
       LayoutIncremental,
       LayoutInitial,
       LayoutLabelPlan,
       LayoutLabelSpec,
       LayoutLeftToRight,
       LayoutLocal,
       LayoutMode,
       LayoutNodeMetric,
       LayoutOptions,
       LayoutOrientation,
       LayoutPage,
       LayoutPlacement,
       LayoutPlan,
       LayoutRequest,
       LayoutResult,
       LayoutRoutePlan,
       LayoutTopDown,
       RepeatedBaySpec,
       layout_project,
       plan_layout

end

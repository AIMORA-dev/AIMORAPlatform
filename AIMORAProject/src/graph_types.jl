@enum GraphFamily::UInt8 begin
    PhysicalGraph = 0x01
    SignalGraph = 0x02
    EventGraph = 0x03
    StudyResultGraph = 0x04
    WorkflowGraph = 0x05
    ViewGraph = 0x06
end

"""A namespaced, versioned domain inside exactly one semantic graph family."""
struct GraphDomainIdentity
    family::GraphFamily
    type::SemanticTypeId
end

Base.:(==)(left::GraphDomainIdentity, right::GraphDomainIdentity) =
    left.family == right.family && left.type == right.type
Base.hash(domain::GraphDomainIdentity, seed::UInt) = hash((domain.family, domain.type), seed)

_aimora_graph_domain(family::GraphFamily, name::AbstractString) = GraphDomainIdentity(
    family,
    SemanticTypeId(NamespaceId("aimora"), ProjectId(name), v"1.0.0"),
)

electrical_ac_domain() = _aimora_graph_domain(PhysicalGraph, "domain.electrical_ac")
electrical_dc_domain() = _aimora_graph_domain(PhysicalGraph, "domain.electrical_dc")
grounding_domain() = _aimora_graph_domain(PhysicalGraph, "domain.grounding")
mechanical_rotational_domain() = _aimora_graph_domain(PhysicalGraph, "domain.mechanical_rotational")
mechanical_translational_domain() = _aimora_graph_domain(PhysicalGraph, "domain.mechanical_translational")
thermal_domain() = _aimora_graph_domain(PhysicalGraph, "domain.thermal")
signal_domain() = _aimora_graph_domain(SignalGraph, "domain.signal")
event_domain() = _aimora_graph_domain(EventGraph, "domain.event")
study_result_domain() = _aimora_graph_domain(StudyResultGraph, "domain.study_result")
workflow_domain() = _aimora_graph_domain(WorkflowGraph, "domain.workflow")
view_domain() = _aimora_graph_domain(ViewGraph, "domain.view")

"""One phase, pole, conductor, carrier, or other domain-owned connection role."""
struct CarrierIdentity
    domain::GraphDomainIdentity
    name::ProjectId
end

Base.:(==)(left::CarrierIdentity, right::CarrierIdentity) =
    left.domain == right.domain && left.name == right.name
Base.hash(carrier::CarrierIdentity, seed::UInt) = hash((carrier.domain, carrier.name), seed)

@enum PortDirection::UInt8 begin
    PortBidirectional = 0x01
    PortInput = 0x02
    PortOutput = 0x03
end

"""The dimensional and orientation contract of one typed signal port."""
struct SignalContract
    dimension::DimensionVector
    unit::UnitId
    orientation::QuantityOrientation
end

Base.:(==)(left::SignalContract, right::SignalContract) =
    left.dimension == right.dimension &&
    left.unit == right.unit &&
    left.orientation == right.orientation

abstract type SemanticGraphElement end
abstract type SemanticConnection <: SemanticGraphElement end

"""A physical node with explicit carriers and optional exact nominal level."""
struct GraphNode <: SemanticGraphElement
    identity::ObjectIdentity
    domain::GraphDomainIdentity
    carriers::CanonicalList{CarrierIdentity}
    nominal_level::Union{Nothing,PhysicalValue{ScalarQuantity}}
    provenance::ProvenanceSource

    function GraphNode(
        identity::ObjectIdentity,
        domain::GraphDomainIdentity,
        carriers::AbstractVector{CarrierIdentity},
        provenance::ProvenanceSource;
        nominal_level::Union{Nothing,PhysicalValue{ScalarQuantity}} = nothing,
    )
        domain.family == PhysicalGraph ||
            _semantic_fail(:invalid_node_domain, "physical node requires a physical graph domain")
        copied = sort!(collect(carriers); by = carrier -> carrier.name.value)
        isempty(copied) && _semantic_fail(:missing_node_carrier, "physical node requires at least one carrier")
        all(carrier -> carrier.domain == domain, copied) ||
            _semantic_fail(:carrier_domain_mismatch, "node carrier belongs to a different domain")
        length(copied) == length(unique(copied)) ||
            _semantic_fail(:duplicate_node_carrier, "physical node repeats a carrier")
        return new(identity, domain, CanonicalList{CarrierIdentity}(copied), nominal_level, provenance)
    end
end

Base.:(==)(left::GraphNode, right::GraphNode) =
    left.identity == right.identity &&
    left.domain == right.domain &&
    left.carriers == right.carriers &&
    left.nominal_level == right.nominal_level &&
    left.provenance == right.provenance

"""A typed asset or block port in either a physical or signal graph."""
struct SemanticPort <: SemanticGraphElement
    identity::ObjectIdentity
    owner::ProjectId
    domain::GraphDomainIdentity
    direction::PortDirection
    carriers::CanonicalList{CarrierIdentity}
    nominal_level::Union{Nothing,PhysicalValue{ScalarQuantity}}
    signal_contract::Union{Nothing,SignalContract}
    provenance::ProvenanceSource

    function SemanticPort(
        identity::ObjectIdentity,
        owner::ProjectId,
        domain::GraphDomainIdentity,
        direction::PortDirection,
        carriers::AbstractVector{CarrierIdentity},
        provenance::ProvenanceSource;
        nominal_level::Union{Nothing,PhysicalValue{ScalarQuantity}} = nothing,
        signal_contract::Union{Nothing,SignalContract} = nothing,
    )
        domain.family in (PhysicalGraph, SignalGraph) ||
            _semantic_fail(:invalid_port_domain, "port requires a physical or signal graph domain")
        copied = sort!(collect(carriers); by = carrier -> carrier.name.value)
        all(carrier -> carrier.domain == domain, copied) ||
            _semantic_fail(:carrier_domain_mismatch, "port carrier belongs to a different domain")
        length(copied) == length(unique(copied)) ||
            _semantic_fail(:duplicate_port_carrier, "port repeats a carrier")
        if domain.family == PhysicalGraph
            direction == PortBidirectional ||
                _semantic_fail(:invalid_physical_port_direction, "physical port must be bidirectional")
            isempty(copied) && _semantic_fail(:missing_port_carrier, "physical port requires carriers")
            isnothing(signal_contract) ||
                _semantic_fail(:signal_contract_on_physical_port, "physical port cannot declare a signal contract")
        else
            direction in (PortInput, PortOutput) ||
                _semantic_fail(:invalid_signal_port_direction, "signal port must be input or output")
            isempty(copied) || _semantic_fail(:carrier_on_signal_port, "signal port cannot declare physical carriers")
            isnothing(nominal_level) || _semantic_fail(:nominal_level_on_signal_port, "signal port cannot declare a physical nominal level")
            isnothing(signal_contract) && _semantic_fail(:missing_signal_contract, "signal port requires a quantity contract")
        end
        return new(
            identity,
            owner,
            domain,
            direction,
            CanonicalList{CarrierIdentity}(copied),
            nominal_level,
            signal_contract,
            provenance,
        )
    end
end

Base.:(==)(left::SemanticPort, right::SemanticPort) =
    left.identity == right.identity &&
    left.owner == right.owner &&
    left.domain == right.domain &&
    left.direction == right.direction &&
    left.carriers == right.carriers &&
    left.nominal_level == right.nominal_level &&
    left.signal_contract == right.signal_contract &&
    left.provenance == right.provenance

struct CarrierMapping
    port_carrier::CarrierIdentity
    node_carrier::CarrierIdentity
end

Base.:(==)(left::CarrierMapping, right::CarrierMapping) =
    left.port_carrier == right.port_carrier && left.node_carrier == right.node_carrier

"""A physical port-to-node connection with an explicit complete carrier map."""
struct PhysicalConnection <: SemanticConnection
    identity::ObjectIdentity
    port::ProjectId
    node::ProjectId
    mappings::CanonicalList{CarrierMapping}
    provenance::ProvenanceSource

    function PhysicalConnection(
        identity::ObjectIdentity,
        port::ProjectId,
        node::ProjectId,
        mappings::AbstractVector{CarrierMapping},
        provenance::ProvenanceSource,
    )
        copied = sort!(collect(mappings); by = mapping -> mapping.port_carrier.name.value)
        isempty(copied) && _semantic_fail(:missing_carrier_mapping, "physical connection requires carrier mappings")
        port_carriers = getfield.(copied, :port_carrier)
        node_carriers = getfield.(copied, :node_carrier)
        length(port_carriers) == length(unique(port_carriers)) ||
            _semantic_fail(:duplicate_port_carrier_mapping, "physical connection maps a port carrier more than once")
        length(node_carriers) == length(unique(node_carriers)) ||
            _semantic_fail(:duplicate_node_carrier_mapping, "physical connection maps a node carrier more than once")
        return new(identity, port, node, CanonicalList{CarrierMapping}(copied), provenance)
    end
end

Base.:(==)(left::PhysicalConnection, right::PhysicalConnection) =
    left.identity == right.identity &&
    left.port == right.port &&
    left.node == right.node &&
    left.mappings == right.mappings &&
    left.provenance == right.provenance

"""A directed typed signal link; delayed links break pure algebraic cycles."""
struct SignalConnection <: SemanticConnection
    identity::ObjectIdentity
    source_port::ProjectId
    target_port::ProjectId
    delayed::Bool
    provenance::ProvenanceSource
end

Base.:(==)(left::SignalConnection, right::SignalConnection) =
    left.identity == right.identity &&
    left.source_port == right.source_port &&
    left.target_port == right.target_port &&
    left.delayed == right.delayed &&
    left.provenance == right.provenance

"""A directed dependency in the declarative workflow graph."""
struct WorkflowDependency <: SemanticConnection
    identity::ObjectIdentity
    upstream::ProjectId
    downstream::ProjectId
    provenance::ProvenanceSource
end

Base.:(==)(left::WorkflowDependency, right::WorkflowDependency) =
    left.identity == right.identity &&
    left.upstream == right.upstream &&
    left.downstream == right.downstream &&
    left.provenance == right.provenance

@enum CrossGraphReferenceKind::UInt8 begin
    EventTargetReference = 0x01
    StudyResultReference = 0x02
    WorkflowInputReference = 0x03
end

"""An explicitly typed reference between graph families, never an untyped edge."""
struct CrossGraphReference <: SemanticGraphElement
    identity::ObjectIdentity
    kind::CrossGraphReferenceKind
    source::ProjectId
    target::ProjectReference
    provenance::ProvenanceSource
end

Base.:(==)(left::CrossGraphReference, right::CrossGraphReference) =
    left.identity == right.identity &&
    left.kind == right.kind &&
    left.source == right.source &&
    left.target == right.target &&
    left.provenance == right.provenance

"""A view-only projection of one semantic owner; it contains no physics or geometry."""
struct ViewProjection <: SemanticGraphElement
    identity::ObjectIdentity
    view::ProjectId
    semantic_owner::ProjectId
    provenance::ProvenanceSource
end


Base.:(==)(left::ViewProjection, right::ViewProjection) =
    left.identity == right.identity &&
    left.view == right.view &&
    left.semantic_owner == right.semantic_owner &&
    left.provenance == right.provenance

"""Separated immutable semantic graph families owned by one canonical project."""
struct SemanticGraphs
    nodes::CanonicalList{GraphNode}
    ports::CanonicalList{SemanticPort}
    physical_connections::CanonicalList{PhysicalConnection}
    signal_connections::CanonicalList{SignalConnection}
    workflow_dependencies::CanonicalList{WorkflowDependency}
    cross_references::CanonicalList{CrossGraphReference}
    view_projections::CanonicalList{ViewProjection}

    function SemanticGraphs(;
        nodes::AbstractVector{GraphNode} = GraphNode[],
        ports::AbstractVector{SemanticPort} = SemanticPort[],
        physical_connections::AbstractVector{PhysicalConnection} = PhysicalConnection[],
        signal_connections::AbstractVector{SignalConnection} = SignalConnection[],
        workflow_dependencies::AbstractVector{WorkflowDependency} = WorkflowDependency[],
        cross_references::AbstractVector{CrossGraphReference} = CrossGraphReference[],
        view_projections::AbstractVector{ViewProjection} = ViewProjection[],
    )
        ordered(items) = sort!(collect(items); by = item -> item.identity.id.value)
        return new(
            CanonicalList{GraphNode}(ordered(nodes)),
            CanonicalList{SemanticPort}(ordered(ports)),
            CanonicalList{PhysicalConnection}(ordered(physical_connections)),
            CanonicalList{SignalConnection}(ordered(signal_connections)),
            CanonicalList{WorkflowDependency}(ordered(workflow_dependencies)),
            CanonicalList{CrossGraphReference}(ordered(cross_references)),
            CanonicalList{ViewProjection}(ordered(view_projections)),
        )
    end
end

Base.:(==)(left::SemanticGraphs, right::SemanticGraphs) =
    left.nodes == right.nodes &&
    left.ports == right.ports &&
    left.physical_connections == right.physical_connections &&
    left.signal_connections == right.signal_connections &&
    left.workflow_dependencies == right.workflow_dependencies &&
    left.cross_references == right.cross_references &&
    left.view_projections == right.view_projections

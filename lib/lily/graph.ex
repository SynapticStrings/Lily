defmodule Lily.Graph do
  @moduledoc """
  The pure mathematical representation of the DAG.
  """

  defmodule Node do
    @moduledoc "A pure data representation of a computation step in the DAG."

    @type id :: atom() | String.t()

    @type t :: %__MODULE__{
            id: id(),
            impl: Orchid.Step.implementation(),
            inputs: [atom()],
            outputs: [atom()],
            opts: keyword(),
            maybe_input_context: %{atom() => any()},
            extra: map()
          }

    defstruct [
      :id,
      :impl,
      inputs: [],
      outputs: [],
      opts: [],
      maybe_input_context: nil,
      extra: %{}
    ]
  end

  defmodule Edge do
    @moduledoc """
    A directed edge representing data flow between two node ports.

    It also serves as the deterministic variable name across the larger system.
    """

    @type t :: %__MODULE__{
            from_node: Node.id(),
            from_port: atom(),
            to_node: Node.id(),
            to_port: atom()
          }

    defstruct [:from_node, :from_port, :to_node, :to_port]

    def new(from_node, from_port, to_node, to_port) do
      %__MODULE__{
        from_node: from_node,
        from_port: from_port,
        to_node: to_node,
        to_port: to_port
      }
    end
  end

  defmodule Portkey do
    @type t :: {:port, node :: Node.id(), port :: atom()}

    @spec to_orchid_key(t()) :: atom()
    def to_orchid_key({:port, node, port}) do
      :"#{node}_#{port}"
    end
  end

  @type t :: %__MODULE__{
          nodes: %{Node.id() => Node.t()} | %{},
          edges: MapSet.t(Edge.t()) | MapSet.t()
        }

  defstruct nodes: %{}, edges: MapSet.new()

  def new, do: %__MODULE__{}

  @spec add_node(t(), Node.t()) :: t()
  def add_node(%__MODULE__{nodes: old_nodes} = graph, %Node{id: node_id} = node) do
    %{graph | nodes: Map.put(old_nodes, node_id, node)}
  end

  @spec remove_node(t(), Node.id()) :: t()
  def remove_node(%__MODULE__{nodes: nodes, edges: edges}, node_id) do
    case nodes[node_id] do
      nil ->
        %__MODULE__{nodes: nodes, edges: edges}

      _ ->
        %__MODULE__{
          nodes: Map.delete(nodes, node_id),
          edges:
            edges
            |> Enum.reject(&(&1.from_node == node_id or &1.to_node == node_id))
            |> Enum.into(%MapSet{})
        }
    end
  end

  @spec update_node(t(), Node.id(), new_node :: Node.t()) :: t()
  def update_node(%__MODULE__{nodes: nodes} = graph, node_id, new_node) do
    case nodes[node_id] do
      nil ->
        graph

      old_node = %Node{} ->
        %{
          graph
          | nodes: %{
              nodes
              | node_id =>
                  case new_node do
                    new_node when is_function(new_node, 1) -> new_node.(old_node)
                    _ -> new_node
                  end
            }
        }
    end
  end

  @spec add_edge(t(), Edge.t()) :: t()
  def add_edge(%__MODULE__{} = graph, edge) do
    %{graph | edges: MapSet.put(graph.edges, edge)}
  end

  @spec remove_edge(t(), Edge.t()) :: t()
  def remove_edge(%__MODULE__{edges: edges} = graph, edge) do
    %{
      graph
      | edges:
          edges
          |> Enum.reject(&(&1 == edge))
          |> Enum.into(%MapSet{})
    }
  end

  @doc "获取指向某节点的所有输入边"
  @spec get_in_edges(t(), Node.t()) :: [Edge.t()]
  def get_in_edges(%__MODULE__{} = graph, node_id) do
    Enum.filter(graph.edges, &(&1.to_node == node_id))
  end

  @doc "获取从某节点发出的所有输出边"
  @spec get_out_edges(t(), Node.t()) :: [Edge.t()]
  def get_out_edges(%__MODULE__{} = graph, node_id) do
    Enum.filter(graph.edges, &(&1.from_node == node_id))
  end

  @spec topological_sort(t()) :: {:ok, [Node.id()]} | {:error, :cycle_detected}
  def topological_sort(%__MODULE__{} = graph) do
    # 1. 初始化所有节点的入度 (In-degree) 为 0
    init_in_degrees = Map.keys(graph.nodes) |> Map.new(fn id -> {id, 0} end) |> Enum.into(%{})

    # 2. 遍历所有边，计算每个节点的真实入度
    in_degrees =
      Enum.reduce(graph.edges, init_in_degrees, fn edge, acc ->
        Map.update!(acc, edge.to_node, &(&1 + 1))
      end)

    # 3. 找出所有入度为 0 的游离节点（图的起始触发点）
    zero_in_degree_nodes =
      in_degrees
      |> Enum.filter(fn {_id, degree} -> degree == 0 end)
      |> Enum.map(fn {id, _degree} -> id end)

    # 4. 开始递归剥离图
    do_topo_sort(zero_in_degree_nodes, in_degrees, graph, [])
  end

  # Kahn 算法的核心递归
  defp do_topo_sort([], _in_degrees, graph, sorted_acc) do
    # 如果已排序的节点数量等于图中的总节点数，说明排序成功
    if length(sorted_acc) == map_size(graph.nodes) do
      {:ok, Enum.reverse(sorted_acc)}
    else
      # 还有节点没被剥离，说明它们互相依赖，形成了死锁（环）！
      {:error, :cycle_detected}
    end
  end

  defp do_topo_sort([node_id | rest_zero_nodes], in_degrees, graph, sorted_acc) do
    # 遍历入度为 0 的边，将它们指向的下游节点的入度减 1
    {new_in_degrees, new_zero_nodes} =
      graph.edges
      |> Enum.filter(&(&1.from_node == node_id))
      |> Enum.reduce({in_degrees, rest_zero_nodes}, fn edge, {deg_acc, zero_acc} ->
        new_deg = deg_acc[edge.to_node] - 1
        deg_acc = Map.put(deg_acc, edge.to_node, new_deg)

        # 如果下游节点的入度变成了 0，将其加入下一轮待处理队列
        case new_deg do
          0 -> {deg_acc, [edge.to_node | zero_acc]}
          _ -> {deg_acc, zero_acc}
        end
      end)

    # 递归处理下一批入度为 0 的节点
    do_topo_sort(new_zero_nodes, new_in_degrees, graph, [node_id | sorted_acc])
  end
end

defmodule Lily.Compiler do
  @moduledoc """
  The final stage of the Lily pure functional pipeline.
  Translates the effective DAG into a sequence of Orchid.Recipe.
  """
  alias Lily.Graph
  alias Lily.Graph.{Node, Portkey, Cluster}

  @type port_key_name :: {:port, target_node :: Node.id(), target_port :: atom()}

  @doc """
  将有效状态和分簇策略编译为 Recipe 序列。
  """
  def compile(
        %{graph: graph, overrides: global_overrides, offsets: global_offsets},
        cluster_declara \\ %Cluster{}
      ) do
    # 1. 确保图是合法的，并拿到拓扑执行顺序
    case Graph.topological_sort(graph) do
      {:error, _} = err ->
        err

      {:ok, sorted_node_ids} ->
        # 2. 染色：决定每个 Node 属于哪个 Cluster
        node_colors =
          Lily.Graph.Cluster.paint_graph(sorted_node_ids, graph.edges, cluster_declara)

        # 3. 按簇分组
        clusters =
          Enum.group_by(
            # 保持拓扑顺序
            sorted_node_ids,
            fn id -> Map.get(node_colors, id, :default_cluster) end
          )

        # 4. 生成 Orchid Recipe
        recipes =
          Enum.map(clusters, fn {cluster_name, node_ids_in_cluster} ->
            build_recipe(cluster_name, node_ids_in_cluster, graph, %{
              overrides: global_overrides,
              offsets: global_offsets
            })
          end)

        {:ok, recipes}
    end
  end

  defp build_recipe(cluster_name, node_ids, graph, %{
         overrides: global_overrides,
         offsets: global_offsets
       }) do
    steps =
      node_ids
      |> Enum.map(&Map.fetch!(graph.nodes, &1))
      |> Enum.map(&node_to_step(&1, graph))

    {requires, exports} = calculate_boundaries(node_ids, graph)

    overrides =
      global_overrides
      |> Enum.filter(fn {{:port, target_node, _port}, _data} ->
        target_node in node_ids
      end)
      |> Enum.into(%{})

    offsets =
      global_offsets
      |> Enum.filter(fn {{:port, target_node, _port}, _data} ->
        target_node in node_ids
      end)
      |> Enum.into(%{})

    %{
      recipe: Orchid.Recipe.new(steps, name: cluster_name),
      requires: requires,
      exports: exports,
      overrides: overrides,
      offsets: offsets
    }
  end

  defp node_to_step(%Node{} = node, graph) do
    in_edges = Graph.get_in_edges(graph, node.id)

    step_inputs =
      Enum.map(node.inputs, fn port_name ->
        case Enum.find(in_edges, &(&1.to_port == port_name)) do
          nil -> Portkey.to_orchid_key({:port, node.id, port_name})
          edge -> Portkey.to_orchid_key({:port, edge.from_node, edge.from_port})
        end
      end)

    step_outputs =
      Enum.map(node.outputs, fn port_name ->
        Portkey.to_orchid_key({:port, node.id, port_name})
      end)

    build_orchid_step(
      node.impl,
      step_inputs,
      step_outputs,
      node.opts
    )
  end

  defp calculate_boundaries(node_ids_in_cluster, graph) do
    cluster_nodes_set = MapSet.new(node_ids_in_cluster)

    # 1. 计算 Requires:
    # a. 来自外部簇的输入边
    external_in_edges =
      graph.edges
      |> Enum.filter(fn e ->
        e.to_node in cluster_nodes_set and e.from_node not in cluster_nodes_set
      end)
      |> Enum.map(fn e -> Portkey.to_orchid_key({:port, e.from_node, e.from_port}) end)

    # b. 完全没有连线的悬空输入 (Dangling Inputs)
    dangling_inputs =
      Enum.flat_map(node_ids_in_cluster, fn node_id ->
        node = graph.nodes[node_id]
        in_edges = Graph.get_in_edges(graph, node_id)

        node.inputs
        |> Enum.reject(fn port -> Enum.any?(in_edges, &(&1.to_port == port)) end)
        |> Enum.map(fn port -> Portkey.to_orchid_key({:port, node.id, port}) end)
      end)

    requires = Enum.uniq(external_in_edges ++ dangling_inputs)

    # 2. 计算 Exports:
    # 流向外部簇的输出边
    exports =
      graph.edges
      |> Enum.filter(fn e ->
        e.from_node in cluster_nodes_set and e.to_node not in cluster_nodes_set
      end)
      |> Enum.map(fn e -> Portkey.to_orchid_key({:port, e.from_node, e.from_port}) end)
      |> Enum.uniq()

    {requires, exports}
  end

  def build_orchid_step(impl, inputs, outputs, opts) do
    {impl, inputs, outputs, opts}
  end
end

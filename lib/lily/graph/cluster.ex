defmodule Lily.Graph.Cluster do
  # 将依赖依照用户选择以及依赖关系分簇
  # 以实现并行控制
  # 人话：将部分很耗费资源的服务单独丢出去
  # 将整个并行改成串行 + 并行
  alias Lily.Graph.{Node, Edge}

  @type cluster_name :: atom() | String.t() | [cluster_name()]

  @type t :: %__MODULE__{
          node_colors: %{Node.id() => cluster_name()},
          merge_groups: [{cluster_name() | MapSet.t(cluster_name()), cluster_name()}]
        }
  defstruct node_colors: %{},
            merge_groups: []

  @spec paint_graph([Node.t()], MapSet.t(Edge.t()), Lily.Graph.Cluster.t()) ::
          %{Node.id() => cluster_name()}
  @doc "Return `%{node_name => final_cluster_name}`"
  def paint_graph(sorted_nodes, edges, %__MODULE__{} = clusters) do
    Enum.reduce(sorted_nodes, %{}, fn node_id, color_map ->
      cond do
        explicit_color = Map.get(clusters.node_colors, node_id) ->
          Map.put(color_map, node_id, explicit_color)

        true ->
          Map.put(color_map, node_id, get_upstream_colors(node_id, edges, color_map))
      end
    end)
    # normalize clusters
    |> Enum.map(fn {k, v} -> {k, case v do v when is_list(v) -> Enum.sort(v); v -> v end} end)
    |> Enum.into(%{})
  end

  defp get_upstream_colors(node_id, edges, color_map) do
    Enum.filter(edges, fn e -> e.to_node == node_id end)
    |> case do
      [] -> []
      _ = upper_edges -> Enum.map(upper_edges, fn e -> e.from_node end)
    end
    |> Enum.map(&Map.get(color_map, &1, :default_cluster))
    # [[:foo, :bar], :bar] => [:foo, :bar]
    |> List.flatten()
    |> Enum.uniq()
  end
end

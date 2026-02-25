defmodule Lily.Compiler do
  @moduledoc """
  The final stage of the Lily pure functional pipeline.
  Translates the effective DAG into a sequence of Orchid.Recipe.
  """
  alias Lily.Graph
  alias Lily.Graph.{Node, Portkey, Cluster}

  @type port_key_name :: {:port, node_id :: Node.id(), port_name :: atom()}

  @doc """
  Stage 1: Compile pure topologies into static Recipes.
  Takes ONLY the graph structure and clustering strategy. Data is ignored here.
  """
  def compile(%Graph{} = graph, cluster_declara \\ %Cluster{}) do
    case Graph.topological_sort(graph) do
      {:error, _} = err ->
        err

      {:ok, sorted_node_ids} ->
        node_colors = Cluster.paint_graph(sorted_node_ids, graph.edges, cluster_declara)

        clusters = Enum.group_by(sorted_node_ids, &Map.get(node_colors, &1, :default_cluster))

        static_recipes =
          Enum.map(clusters, fn {cluster_name, node_ids_in_cluster} ->
            build_recipe(cluster_name, node_ids_in_cluster, graph)
          end)

        {:ok, static_recipes}
    end
  end

  @doc """
  Stage 2: Downstream mapping function.
  Hydrates the compiled topology with `init_data` (inputs, overrides, offsets).
  """
  def bind_interventions(static_recipes, %{inputs: inputs, overrides: overrides, offsets: offsets}) do
    Enum.map(static_recipes, fn %{recipe: recipe} = static_bundle ->
      # Extract node ids involved in this specific recipe cluster
      node_ids_in_cluster = extract_recipe_nodes(recipe)

      # Filter data relevant to this cluster
      local_inputs = filter_port_data(inputs, node_ids_in_cluster)
      local_overrides = filter_port_data(overrides, node_ids_in_cluster)
      local_offsets = filter_port_data(offsets, node_ids_in_cluster)

      static_bundle
      |> Map.put(:overrides, local_overrides)
      |> Map.put(:offsets, local_offsets)
      |> Map.put(:inputs, local_inputs)
    end)
  end

  defp build_recipe(cluster_name, node_ids, graph) do
    steps =
      node_ids
      |> Enum.map(&Map.fetch!(graph.nodes, &1))
      |> Enum.map(&node_to_step(&1, graph))

    {requires, exports} = calculate_boundaries(node_ids, graph)

    # Strictly returns ONLY topology data
    %{
      recipe: Orchid.Recipe.new(steps, name: cluster_name),
      requires: requires,
      exports: exports
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

    step_outputs = Enum.map(node.outputs, fn p -> Portkey.to_orchid_key({:port, node.id, p}) end)

    build_orchid_step(node.impl, step_inputs, step_outputs, node.opts)
  end

  defp calculate_boundaries(node_ids_in_cluster, graph) do
    cluster_nodes_set = MapSet.new(node_ids_in_cluster)

    external_in_edges =
      graph.edges
      |> Enum.filter(&(&1.to_node in cluster_nodes_set and &1.from_node not in cluster_nodes_set))
      |> Enum.map(&Portkey.to_orchid_key({:port, &1.from_node, &1.from_port}))

    dangling_inputs =
      Enum.flat_map(node_ids_in_cluster, fn node_id ->
        node = graph.nodes[node_id]
        in_edges = Graph.get_in_edges(graph, node_id)

        node.inputs
        |> Enum.reject(fn port -> Enum.any?(in_edges, &(&1.to_port == port)) end)
        |> Enum.map(fn port -> Portkey.to_orchid_key({:port, node.id, port}) end)
      end)

    requires = Enum.uniq(external_in_edges ++ dangling_inputs)

    exports =
      graph.edges
      |> Enum.filter(&(&1.from_node in cluster_nodes_set and &1.to_node not in cluster_nodes_set))
      |> Enum.map(&Portkey.to_orchid_key({:port, &1.from_node, &1.from_port}))
      |> Enum.uniq()

    {requires, exports}
  end

  defp filter_port_data(data_map, node_ids) do
    data_map
    |> Enum.filter(fn {{:port, target_node, _port}, _data} -> target_node in node_ids end)
    |> Enum.into(%{})
  end

  defp extract_recipe_nodes(%Orchid.Recipe{steps: steps}) do
    # Assuming step format is {Impl, Inputs, Outputs, Opts} and outputs start with "nodeid_port"
    # An alternative is storing node_ids in the recipe metadata.
    # We will simulate node extraction based on output keys:
    Enum.flat_map(steps, fn {_impl, _in, outs, _opts} ->
      Enum.map(outs, fn out_key ->
        out_key |> Atom.to_string() |> String.split("_") |> hd() |> String.to_atom()
      end)
    end) |> Enum.uniq()
  end

  def build_orchid_step(impl, inputs, outputs, opts) do
    {impl, inputs, outputs, opts}
  end
end

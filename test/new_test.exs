defmodule LilyCompilerTest do
  use ExUnit.Case

  alias Lily.Graph
  alias Lily.Graph.{Node, Edge, Cluster}
  alias Lily.Compiler

  defp build_test_graph do
    nodes = [
      %Node{id: :split, impl: :dummy, inputs: [:val], outputs: [:out_a, :out_b]},
      %Node{id: :add,   impl: :dummy, inputs: [:a, :b], outputs: [:res]},
      %Node{id: :mul,   impl: :dummy, inputs: [:a, :b], outputs: [:res]},
      %Node{id: :inc,   impl: :dummy, inputs: [:val], outputs: [:res]},
      %Node{id: :dec,   impl: :dummy, inputs: [:val], outputs: [:res]}
    ]

    edges = [
      %Edge{from_node: :split, from_port: :out_a, to_node: :inc, to_port: :val},
      %Edge{from_node: :split, from_port: :out_b, to_node: :dec, to_port: :val},
      %Edge{from_node: :inc,   from_port: :res,   to_node: :add, to_port: :a},
      %Edge{from_node: :dec,   from_port: :res,   to_node: :add, to_port: :b},
      %Edge{from_node: :add,   from_port: :res,   to_node: :mul, to_port: :a}
    ]

    graph = Graph.new()
    graph = Enum.reduce(nodes, graph, &Graph.add_node(&2, &1))
    graph = Enum.reduce(edges, graph, &Graph.add_edge(&2, &1))

    graph
  end

  test "图拓扑排序正确 (Topological Sort)" do
    graph = build_test_graph()
    {:ok, sorted_ids} = Graph.topological_sort(graph)

    assert hd(sorted_ids) == :split

    assert Enum.find_index(sorted_ids, &(&1 == :add)) > Enum.find_index(sorted_ids, &(&1 == :inc))
    assert Enum.find_index(sorted_ids, &(&1 == :add)) > Enum.find_index(sorted_ids, &(&1 == :dec))

    assert List.last(sorted_ids) == :mul
  end

  test "编译器：单集群编译与悬空参数识别" do
    graph = build_test_graph()

    {:ok, recipes} = Compiler.compile(graph)

    assert length(recipes) == 1
    recipe = hd(recipes)

    assert :split_val in recipe.requires
    assert :mul_b in recipe.requires

    refute :inc_res in recipe.requires
  end

  test "编译器：硬核分簇切割与跨边缝合 (Cut & Bridge)" do
    graph = build_test_graph()

    cluster_declara = %Cluster{
      node_colors: %{
        split: :cpu_cluster,
        inc:   :cpu_cluster,
        dec:   :cpu_cluster,
        add:   :gpu_cluster,
        mul:   :gpu_cluster
      }
    }

    {:ok, recipes} = Compiler.compile(graph, cluster_declara)

    assert length(recipes) == 2

    cpu_recipe = Enum.find(recipes, &(&1[:recipe].name == :cpu_cluster))
    gpu_recipe = Enum.find(recipes, &(&1[:recipe].name == :gpu_cluster))

    assert :split_val in cpu_recipe.requires

    assert :inc_res in cpu_recipe.exports
    assert :dec_res in cpu_recipe.exports

    assert :inc_res in gpu_recipe.requires
    assert :dec_res in gpu_recipe.requires

    assert :mul_b in gpu_recipe.requires
  end

  test "编译器：两阶段编译 - 拓扑切割与数据缝合" do
    graph = build_test_graph()
    
    # 模拟 History 得到的 init_data (包含 inputs, overrides 等)
    init_data = %{
      inputs: %{ {:port, :split, :val} => 42 },
      overrides: %{ {:port, :inc, :res} => 100 },
      offsets: %{}
    }

    cluster_declara = %Cluster{
      node_colors: %{
        split: :cpu_cluster,
        inc:   :cpu_cluster,
        dec:   :cpu_cluster,
        add:   :gpu_cluster,
        mul:   :gpu_cluster
      }
    }

    # 第一阶段：纯拓扑编译
    {:ok, static_recipes} = Compiler.compile(graph, cluster_declara)

    assert length(static_recipes) == 2
    
    cpu_recipe = Enum.find(static_recipes, &(&1[:recipe].name == :cpu_cluster))
    assert :split_val in cpu_recipe.requires
    refute Map.has_key?(cpu_recipe, :overrides) # 确保没有包含侧载数据

    # 第二阶段：数据绑定 (Downstream Enumerable Mapping)
    final_bundles = Compiler.bind_interventions(static_recipes, init_data)
    
    # 验证数据是否被正确分发到对应的 bundle
    cpu_bundle = Enum.find(final_bundles, &(&1[:recipe].name == :cpu_cluster))
    gpu_bundle = Enum.find(final_bundles, &(&1[:recipe].name == :gpu_cluster))

    # CPU 集群包含了 :split 的 input 和 :inc 的 override
    assert cpu_bundle.inputs[{:port, :split, :val}] == 42
    assert cpu_bundle.overrides[{:port, :inc, :res}] == 100
    
    # GPU 集群没有任何干预数据
    assert map_size(gpu_bundle.overrides) == 0
  end
end

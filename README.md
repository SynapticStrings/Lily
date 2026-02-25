# 🌸Lily

**The pure functional DAG and compilation core.**

Lily handles the mathematical topology, user edit history, and execution plan generation for interactive editors. It delegates all side-effects and hardware scheduling to its host engine.

## 🎯 Philosophy

*   **Pure Data:** No GenServers, no ETS, zero side-effects.
*   **Time Travel:** O(1) Undo/Redo with zero memory copying.
*   **Deterministic:** Compiles user interventions and topological splits into strictly consistent `Orchid.Recipe`s.

## 🏗️ Architecture

1.  **`Lily.Graph`**: A strict, port-centric DAG. Connections and variables are defined by immutable keys (`{:port, node_id, port_name}`).
2.  **`Lily.History`**: A double-stack event sourcer. It folds chronological operations (node mutations, data overrides) into a single `effective_state`.
3.  **`Lily.Compiler`**: The translator. It partitions the graph into clusters (e.g., splitting heavy GPU nodes from CPU nodes), bridges cut edges via `requires/exports`, and maps user overrides into Orchid's execution baggage.

## 🚀 Quick Start

```elixir
alias Lily.{Graph, Graph.Node, Graph.Edge, Graph.Cluster, History, Compiler}

# 1. Build the static topology
graph = Graph.new()
|> Graph.add_node(%Node{id: :acoustic, inputs: [:lyrics], outputs: [:mel]})
|> Graph.add_node(%Node{id: :vocoder,  inputs: [:mel], outputs: [:audio]})
|> Graph.add_edge(Edge.new(:acoustic, :mel, :vocoder, :mel))

# 2. Record user interventions (e.g., overriding AI tensors via UI)
history = History.new()
|> History.push({:override, {:port, :vocoder, :mel}, <<0, 1, "tensor_data">>})

# 3. Fold history into the current effective state
state = History.resolve(graph, history)

# 4. Compile & Partition (Split execution to prevent VRAM overflow)
clusters = %Cluster{node_colors: %{acoustic: :gpu_1, vocoder: :gpu_2}}
{:ok, [recipe_1, recipe_2]} = Compiler.compile(state, clusters)

# Result: 
# recipe_1 exports :"acoustic_mel"
# recipe_2 requires :"acoustic_mel" and carries the user override in its baggage.
```
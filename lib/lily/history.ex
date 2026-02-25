defmodule Lily.History do
  defmodule Operation do
    alias Lily.Graph.{Node, Edge, Portkey}

    @type edge_key ::
            {:edge, from_node :: atom(), from_port :: atom(), to_node :: atom(),
             to_port :: atom()}

    @type topology_mutation ::
            {:add_node, Node.t()}
            | {:update_node, Node.id(),
               node_or_update_funtion :: Node.t() | (Node.t() -> Node.t())}
            | {:remove_node, Node.id()}
            | {:add_edge, Edge.t()}
            | {:remove_edge, Edge.t()}

    @type input_declar ::
            {:set_input, Portkey.t(), data :: any()}
            | {:remove_input, Portkey.t()}

    @type data_interventions ::
            {:override, Portkey.t(), data :: any()}
            | {:offset, Portkey.t(), data :: any()}
            | {:remove_interventions, Portkey.t()}

    @type t :: topology_mutation() | data_interventions() | input_declar()
  end

  alias Lily.Graph.Portkey
  alias Lily.Graph

  @type t :: %__MODULE__{
          # 越新的操作越靠前 (Head)
          undo_stack: [Operation.t()],
          # 越靠近当前时间点的“未来”越靠前
          redo_stack: [Operation.t()]
        }

  defstruct undo_stack: [], redo_stack: []

  @doc "初始化一个新的历史记录"
  def new, do: %__MODULE__{}

  @spec push(Lily.History.t(), any()) :: Lily.History.t()
  def push(%__MODULE__{undo_stack: undo} = history, op) do
    %{history | undo_stack: [op | undo], redo_stack: []}
  end

  @spec undo(Lily.History.t()) :: Lily.History.t()
  def undo(%__MODULE__{undo_stack: []} = history), do: history

  def undo(%__MODULE__{undo_stack: [last_op | rest_undo], redo_stack: redo} = history) do
    %{history | undo_stack: rest_undo, redo_stack: [last_op | redo]}
  end

  @spec redo(Lily.History.t()) :: Lily.History.t()
  def redo(%__MODULE__{redo_stack: []} = history), do: history

  def redo(%__MODULE__{undo_stack: undo, redo_stack: [next_op | rest_redo]} = history) do
    %{history | undo_stack: [next_op | undo], redo_stack: rest_redo}
  end

  @type effective_state :: %{
          graph: Lily.Graph.t(),
          inputs: %{Lily.Graph.Portkey.t() => any()},
          overrides: %{Lily.Graph.Portkey.t() => any()},
          offsets: %{Lily.Graph.Portkey.t() => any()}
        }

  @doc """
  将所有的历史记录（过去）按时间顺序叠加到 base_graph 上。
  输出 Compiler 和 Orchid 真正需要的有效状态。
  """
  @spec resolve(Graph.t(), t()) :: effective_state()
  def resolve(%Graph{} = base_graph, %__MODULE__{undo_stack: undo_stack}) do
    initial_state = %{graph: base_graph, inputs: %{}, overrides: %{}, offsets: %{}}

    undo_stack
    |> Rnum.reverse()
    |> Enum.reduce(initial_state, &apply_operation/2)
  end

  defp apply_operation({:add_node, node}, state) do
    %{state | graph: Graph.add_node(state.graph, node)}
  end

  defp apply_operation({:update_node, node_id, new_node}, state) do
    %{state | graph: Graph.update_node(state.graph, node_id, new_node)}
  end

  defp apply_operation({:remove_node, node_id}, state) do
    %{state | graph: Graph.remove_node(state.graph, node_id)}
  end

  defp apply_operation({:add_edge, edge}, state) do
    %{state | graph: Graph.add_edge(state.graph, edge)}
  end

  defp apply_operation({:remove_edge, edge}, state) do
    %{state | graph: Graph.remove_edge(state.graph, edge)}
  end

  defp apply_operation({:override, {:port, _, _} = port_key, value}, state) do
    %{state | overrides: Map.put(state.overrides, port_key, value)}
  end

  defp apply_operation({:offset, {:port, _, _} = port_key, value}, state) do
    %{state | offsets: Map.put(state.offsets, port_key, value)}
  end

  defp apply_operation({:remove_interventions, {:port, _, _} = port_key}, state) do
    %{
    state
    | overrides: Map.delete(state.overrides, port_key),
      offsets: Map.delete(state.offsets, port_key)
  }
  end

  defp apply_operation({:set_input, port_key, data}, state) do
    %{state | inputs: Map.put(state.inputs, port_key, data)}
  end

  defp apply_operation({:remove_input, port_key}, state) do
    %{state | inputs: Map.delete(state.inputs, port_key)}
  end
end

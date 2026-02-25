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
            {:update_node_input, Node.id(), port_id :: atom(), new_input :: any()}
            | {:remove_node_input, Node.id(), port_id :: atom()}

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
          graph: Graph.t(),
          overrides: %{Portkey.t() => any()},
          offsets: %{Portkey.t() => any()}
        }

  @doc """
  将所有的历史记录（过去）按时间顺序叠加到 base_graph 上。
  输出 Compiler 和 Orchid 真正需要的有效状态。
  """
  @spec resolve(Graph.t(), t()) :: effective_state()
  def resolve(%Graph{} = base_graph, %__MODULE__{undo_stack: undo_stack}) do
    # 为什么要 reverse？因为 undo_stack 的头部是最新的操作，
    # 我们要像看电影一样，从最古老的操作开始依次重播 (Replay)。
    chronological_ops = Enum.reverse(undo_stack)

    # 初始的折叠状态：图是原图，覆盖数据是空的
    initial_state = %{graph: base_graph, overrides: %{}, offsets: %{}}

    Enum.reduce(chronological_ops, initial_state, &apply_operation/2)
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

  # defp apply_operation({:update_node_input, node_id, node_port, new_input}, state) do
  #   apply_operation(
  #     {:update_node, node_id,
  #      fn node = %Graph.Node{} -> %{node | maybe_input_context: new_input} end},
  #     state
  #   )
  # end
end

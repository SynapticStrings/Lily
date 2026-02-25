defmodule LilyTest do
  use ExUnit.Case
  doctest Lily

  test "greets the world" do
    assert Lily.hello() == :world
  end
end

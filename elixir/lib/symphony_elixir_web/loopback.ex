defmodule SymphonyElixirWeb.Loopback do
  @moduledoc """
  Shared loopback address detection for local operator surfaces.
  """

  @spec loopback?(term()) :: boolean()
  def loopback?({127, _, _, _}), do: true
  def loopback?({0, 0, 0, 0, 0, 0, 0, 1}), do: true
  def loopback?({0, 0, 0, 0, 0, 65_535, high, _low}) when high in 32_512..32_767, do: true
  def loopback?(_remote_ip), do: false
end

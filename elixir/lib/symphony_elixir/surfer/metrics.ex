defmodule SymphonyElixir.Surfer.Metrics do
  @moduledoc """
  Minimal telemetry surface for Surfer operations.
  """

  alias SymphonyElixir.Surfer.SecretRedactor

  @spec emit(atom(), map(), map()) :: :ok
  def emit(name, measurements \\ %{count: 1}, metadata \\ %{}) when is_atom(name) do
    :telemetry.execute([:symphony, :surfer, name], measurements, SecretRedactor.redact(metadata))
    :ok
  end
end
